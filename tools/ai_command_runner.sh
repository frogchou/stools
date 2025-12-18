#!/usr/bin/env python3
"""
AI command runner tool for stools.

Workflow:
1. Accept a natural language command from the user.
2. Call the OpenAI Chat Completions API with a strict prompt so the model returns only runnable code.
3. Save the returned code to a temporary script in /tmp and make it executable.
4. Execute the generated script, capturing output and errors.
5. Summarize the result alongside the original command.

The script performs validation at each step and reports progress to the user.
"""

import json
import os
import sys
import tempfile
import textwrap
import time
from subprocess import CompletedProcess, run
from typing import Dict
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

DEFAULT_MODEL = os.environ.get("OPENAI_MODEL", "gpt-4o-mini")
DEFAULT_BASE_URL = os.environ.get("OPENAI_API_BASE_URL", "https://api.openai.com/v1")
DEFAULT_TIMEOUT = 120


def log_step(message: str) -> None:
    print(f"➡️  {message}")


def log_success(message: str) -> None:
    print(f"✅ {message}")


def log_error(message: str) -> None:
    print(f"❌ {message}", file=sys.stderr)


def require_api_key() -> str:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        log_error("环境变量 OPENAI_API_KEY 未设置，无法调用 OpenAI API。")
        sys.exit(1)
    return api_key


def build_prompt(user_command: str) -> str:
    return textwrap.dedent(
        f"""
        你是一个可以根据需求编写脚本的助理。
        - 只返回代码，不要使用 Markdown、解释或额外文本。
        - 生成兼容性的 POSIX shell 脚本，第一行必须是 #!/usr/bin/env sh。
        - 脚本必须避免交互式操作，使用安全默认值，并在遇到错误时以非零状态退出，如果遇到错误尽可能的详细的输出错误。
        - 任务描述：{user_command}
        """
    ).strip()


def call_openai(
    api_key: str,
    prompt: str,
    *,
    model: str = DEFAULT_MODEL,
    base_url: str = DEFAULT_BASE_URL,
    system_prompt: str = "你是一个只输出可运行脚本代码的助理。",
) -> str:
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }
    body: Dict[str, object] = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0,
    }

    request = Request(
        url=f"{base_url.rstrip('/')}/chat/completions",
        data=json.dumps(body).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    try:
        with urlopen(request, timeout=DEFAULT_TIMEOUT) as response:
            data = json.load(response)
    except HTTPError as exc:
        log_error(f"OpenAI API 返回错误状态码 {exc.code}: {exc.reason}")
        sys.exit(1)
    except URLError as exc:
        log_error(f"无法连接到 OpenAI API: {exc.reason}")
        sys.exit(1)

    choice = data.get("choices", [{}])[0]
    message = choice.get("message", {})
    content = message.get("content")
    if not content:
        log_error("OpenAI API 未返回内容，请检查提示词或模型配置。")
        sys.exit(1)
    return content.strip()


def save_script(code: str) -> str:
    if not code.startswith("#!/"):
        code = "#!/usr/bin/env sh\n" + code

    fd, path = tempfile.mkstemp(prefix="stl_ai_", suffix=".sh", dir="/tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as temp_file:
        temp_file.write(code)
    os.chmod(path, 0o700)
    return path


def execute_script(path: str) -> CompletedProcess:
    return run([path], capture_output=True, text=True)


def summarize(command: str, execution: CompletedProcess) -> str:
    output_lines = []
    if execution.stdout:
        output_lines.append(execution.stdout.strip())
    if execution.stderr:
        output_lines.append(f"stderr: {execution.stderr.strip()}")

    combined_output = "\n".join(output_lines) if output_lines else "(无输出)"
    status = "成功" if execution.returncode == 0 else f"失败 (exit={execution.returncode})"
    return f"命令: {command}\n执行状态: {status}\n执行输出: {combined_output}"


def build_analysis_prompt(command: str, execution_summary: str) -> str:
    return textwrap.dedent(
        f"""
        你是一名面向非技术用户的简报助手。
        - 根据用户的原始命令和脚本执行结果，给出简洁、易懂的总结。
        - 用中文输出，不要包含 Markdown、列表或多余格式，只输出结论。
        - 若脚本执行失败，请指出失败原因并给出可行的下一步建议（保持简短）。

        用户命令：{command}
        执行结果：{execution_summary}
        """
    ).strip()


def main() -> None:
    if len(sys.argv) < 2:
        log_error("请提供要执行的命令描述。例如: ./ai_command_runner.py \"查看系统中处于监听状态的端口\"")
        sys.exit(1)

    user_command = " ".join(sys.argv[1:]).strip()
    if not user_command:
        log_error("命令描述不能为空。")
        sys.exit(1)

    api_key = require_api_key()

    log_step("构建提示词并请求 OpenAI 生成脚本...")
    prompt = build_prompt(user_command)
    code = call_openai(api_key=api_key, prompt=prompt)
    log_success("已从 OpenAI 获得脚本代码。")

    log_step("保存脚本到 /tmp 并添加执行权限...")
    script_path = save_script(code)
    log_success(f"脚本已保存: {script_path}")

    log_step("执行生成的脚本...")
    start_time = time.time()
    result = execute_script(script_path)
    duration = time.time() - start_time
    log_success(f"脚本执行完成，用时 {duration:.2f} 秒。")

    log_step("整理执行输出...")
    execution_summary = summarize(user_command, result)

    log_step("请求 OpenAI 对结果进行通俗汇报...")
    analysis_prompt = build_analysis_prompt(user_command, execution_summary)
    analysis = call_openai(
        api_key=api_key,
        prompt=analysis_prompt,
        system_prompt="你是一名中文简报助手，如果遇到错误需要分析错误原因，如果没有错误只输出简短的结论。",
    )

    print("\n===== 汇报 =====")
    print(analysis)

    if result.returncode != 0:
        sys.exit(result.returncode)


if __name__ == "__main__":
    main()
