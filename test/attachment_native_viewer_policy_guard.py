#!/usr/bin/env python3
"""Exact-context guard for the Android native loader policy and CI selection."""

from __future__ import annotations

import re
import sys
from pathlib import Path


STEP_NAME = "Test Android private-file destination policies"
EXPECTED_COMMAND = [
    "java -Dorg.gradle.appname=gradlew",
    "-classpath gradle/wrapper/gradle-wrapper.jar",
    "org.gradle.wrapper.GradleWrapperMain",
    ":app:testDebugUnitTest",
    "--tests app.archivale.AttachmentViewerPolicyTest",
    "--tests app.archivale.AttachmentCustodyNativeAccessTest",
    "--tests app.archivale.ExportSaveCopyPolicyTest",
    "--tests app.archivale.ExportSaveCallbackPolicyTest",
]


class GuardFailure(RuntimeError):
    pass


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _unique_line(lines: list[str], pattern: re.Pattern[str], label: str) -> int:
    matches = [index for index, line in enumerate(lines) if pattern.fullmatch(line)]
    if len(matches) != 1:
        raise GuardFailure(f"expected exactly one {label}; found {len(matches)}")
    return matches[0]


def _code_only(source: str) -> str:
    output = list(source)
    index = 0
    state = "code"
    while index < len(source):
        char = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "line-comment":
            if char == "\n":
                state = "code"
            else:
                output[index] = " "
        elif state == "block-comment":
            if char == "*" and following == "/":
                output[index] = output[index + 1] = " "
                state = "code"
                index += 1
            elif char != "\n":
                output[index] = " "
        elif state in {"string", "char"}:
            output[index] = " " if char != "\n" else "\n"
            if char == "\\":
                if index + 1 < len(source):
                    output[index + 1] = " "
                    index += 1
            elif (state == "string" and char == '"') or (state == "char" and char == "'"):
                state = "code"
        elif char == "/" and following == "/":
            output[index] = output[index + 1] = " "
            state = "line-comment"
            index += 1
        elif char == "/" and following == "*":
            output[index] = output[index + 1] = " "
            state = "block-comment"
            index += 1
        elif char == '"':
            output[index] = " "
            state = "string"
        elif char == "'":
            output[index] = " "
            state = "char"
        index += 1
    return "".join(output)


def validate_workflow(source: str) -> None:
    lines = source.splitlines()
    step_index = _unique_line(
        lines,
        re.compile(rf"^(\s*)- name: {re.escape(STEP_NAME)}\s*$"),
        "Android policy test step",
    )
    step_indent = _indent(lines[step_index])
    step_end = len(lines)
    for index in range(step_index + 1, len(lines)):
        if lines[index].strip() and _indent(lines[index]) <= step_indent:
            step_end = index
            break
    step_lines = lines[step_index + 1 : step_end]
    _unique_line(
        step_lines,
        re.compile(r"^\s+working-directory: android\s*$"),
        "Android working directory in the policy test step",
    )
    run_relative = _unique_line(
        step_lines,
        re.compile(r"^\s+run: >-\s*$"),
        "folded run command in the policy test step",
    )
    run_index = step_index + 1 + run_relative
    run_indent = _indent(lines[run_index])
    command_lines: list[str] = []
    for line in lines[run_index + 1 : step_end]:
        if line.strip() and _indent(line) <= run_indent:
            break
        if line.strip():
            command_lines.append(line.strip())
    if command_lines != EXPECTED_COMMAND:
        raise GuardFailure("Android policy test step does not contain the exact active command")
    for token in EXPECTED_COMMAND[4:]:
        occurrences = sum(line.count(token) for line in lines)
        if occurrences != 1:
            raise GuardFailure(f"expected exactly one active workflow token {token!r}; found {occurrences}")


def _braced_block(source: str, marker: str, label: str) -> str:
    code = _code_only(source)
    if code.count(marker) != 1:
        raise GuardFailure(f"expected exactly one {label} marker")
    opening = code.find("{", code.index(marker) + len(marker))
    if opening < 0:
        raise GuardFailure(f"missing body for {label}")
    depth = 0
    for index in range(opening, len(code)):
        char = code[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return code[opening : index + 1]
    raise GuardFailure(f"unterminated body for {label}")


def _matching_brace(source: str, opening: int, label: str) -> int:
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    raise GuardFailure(f"unterminated braced body for {label}")


def _require_linkage_catch_for_call(block: str, call: str, label: str) -> None:
    if block.count(call) != 1:
        raise GuardFailure(f"expected exactly one protected call in {label}")
    call_index = block.index(call)
    enclosing_tries: list[tuple[int, int]] = []
    for match in re.finditer(r"\btry\s*\{", block):
        opening = block.index("{", match.start())
        closing = _matching_brace(block, opening, label)
        if opening < call_index < closing:
            enclosing_tries.append((opening, closing))
    if not enclosing_tries:
        raise GuardFailure(f"protected call is not inside a try in {label}")

    _, closing = max(enclosing_tries)
    catches: list[str] = []
    cursor = closing + 1
    while match := re.match(r"\s*catch\s*\(([^)]*)\)\s*\{", block[cursor:]):
        catches.append(match.group(1))
        opening = cursor + match.end() - 1
        cursor = _matching_brace(block, opening, label) + 1
    linkage_catches = [
        catch for catch in catches if re.fullmatch(r"\s*_\s*:\s*LinkageError\s*", catch)
    ]
    if len(linkage_catches) != 1:
        raise GuardFailure(
            f"expected one LinkageError catch on the protected try in {label}; "
            f"found {len(linkage_catches)}"
        )


def validate_kotlin(native_access: str, activity: str) -> None:
    access_class = _braced_block(
        native_access,
        "internal class AttachmentCustodyNativeAccess(",
        "AttachmentCustodyNativeAccess",
    )
    _require_linkage_catch_for_call(
        _braced_block(
            access_class,
            "private val libraryAvailable: Boolean by lazy(LazyThreadSafetyMode.SYNCHRONIZED)",
            "libraryAvailable loader",
        ),
        "loadLibrary()",
        "libraryAvailable loader",
    )
    _require_linkage_catch_for_call(
        _braced_block(access_class, "fun execute(", "native execute entry"),
        "bindings.execute(",
        "native execute entry",
    )
    _require_linkage_catch_for_call(
        _braced_block(access_class, "fun openExportPair(", "native openExportPair entry"),
        "bindings.openExportPair(",
        "native openExportPair entry",
    )
    _require_linkage_catch_for_call(
        _braced_block(
            activity,
            "private fun openValidatedExportSource(",
            "Save openValidatedExportSource entry",
        ),
        "AttachmentCustodyNative.openExportPair(",
        "Save openValidatedExportSource entry",
    )


def validate(workflow: str, native_access: str, activity: str) -> None:
    validate_workflow(workflow)
    validate_kotlin(native_access, activity)


def _replace_once(source: str, old: str, new: str, label: str) -> str:
    if source.count(old) != 1:
        raise GuardFailure(f"fixture expected exactly one {label}")
    return source.replace(old, new, 1)


def self_test(workflow: str, native_access: str, activity: str) -> None:
    validate(workflow, native_access, activity)
    selector = "          --tests app.archivale.AttachmentCustodyNativeAccessTest"
    mutations = {
        "commented loader-test selector": (
            _replace_once(workflow, selector, f"          # {selector.strip()}", "loader selector"),
            native_access,
            activity,
        ),
        "removed loader-test selector": (
            _replace_once(workflow, f"{selector}\n", "", "loader selector"),
            native_access,
            activity,
        ),
        "moved loader-test selector": (
            _replace_once(workflow, selector, "      # moved loader test\n" + selector, "loader selector"),
            native_access,
            activity,
        ),
        "duplicate loader-test selector decoy": (
            workflow + f"\n# {selector.strip()}\n",
            native_access,
            activity,
        ),
        "narrowed loader catch": (
            workflow,
            _replace_once(
                native_access,
                "        } catch (_: LinkageError) {\n            false",
                "        } catch (_: UnsatisfiedLinkError) {\n            false",
                "loader catch",
            ),
            activity,
        ),
        "narrowed native execute catch": (
            workflow,
            _replace_once(
                native_access,
                "        } catch (_: LinkageError) {\n            linkageUnavailable.set(true)\n            null",
                "        } catch (_: UnsatisfiedLinkError) {\n            linkageUnavailable.set(true)\n            null",
                "native execute catch",
            ),
            activity,
        ),
        "narrowed native openExportPair catch": (
            workflow,
            _replace_once(
                native_access,
                "        } catch (_: LinkageError) {\n            linkageUnavailable.set(true)\n            IntArray(0)",
                "        } catch (_: UnsatisfiedLinkError) {\n            linkageUnavailable.set(true)\n            IntArray(0)",
                "native openExportPair catch",
            ),
            activity,
        ),
        "narrowed Save catch": (
            workflow,
            native_access,
            _replace_once(
                activity,
                "        } catch (_: LinkageError) {\n            try {\n                payload?.close()",
                "        } catch (_: UnsatisfiedLinkError) {\n            try {\n                payload?.close()",
                "Save catch",
            ),
        ),
        "relocated loader catch decoy": (
            workflow,
            _replace_once(
                _replace_once(
                    native_access,
                    "        } catch (_: LinkageError) {\n            false",
                    "        } catch (_: UnsatisfiedLinkError) {\n            false",
                    "loader catch",
                ),
                "        try {\n            loadLibrary()",
                "        try {\n            Unit\n        } catch (_: LinkageError) {\n"
                "            Unit\n        }\n        try {\n            loadLibrary()",
                "loader try",
            ),
            activity,
        ),
        "relocated native execute catch decoy": (
            workflow,
            _replace_once(
                _replace_once(
                    native_access,
                    "        } catch (_: LinkageError) {\n            linkageUnavailable.set(true)\n            null",
                    "        } catch (_: UnsatisfiedLinkError) {\n            linkageUnavailable.set(true)\n            null",
                    "native execute catch",
                ),
                "        return try {\n            bindings.execute(",
                "        try {\n            Unit\n        } catch (_: LinkageError) {\n"
                "            Unit\n        }\n        return try {\n            bindings.execute(",
                "native execute try",
            ),
            activity,
        ),
        "relocated native openExportPair catch decoy": (
            workflow,
            _replace_once(
                _replace_once(
                    native_access,
                    "        } catch (_: LinkageError) {\n            linkageUnavailable.set(true)\n            IntArray(0)",
                    "        } catch (_: UnsatisfiedLinkError) {\n            linkageUnavailable.set(true)\n            IntArray(0)",
                    "native openExportPair catch",
                ),
                "        return try {\n            bindings.openExportPair(",
                "        try {\n            Unit\n        } catch (_: LinkageError) {\n"
                "            Unit\n        }\n        return try {\n            bindings.openExportPair(",
                "native openExportPair try",
            ),
            activity,
        ),
        "relocated Save catch decoy": (
            workflow,
            native_access,
            _replace_once(
                _replace_once(
                    activity,
                    "        } catch (_: LinkageError) {\n            try {\n                payload?.close()",
                    "        } catch (_: UnsatisfiedLinkError) {\n            try {\n                payload?.close()",
                    "Save catch",
                ),
                "        return try {\n            val descriptors = AttachmentCustodyNative.openExportPair(",
                "        try {\n            Unit\n        } catch (_: LinkageError) {\n"
                "            Unit\n        }\n        return try {\n"
                "            val descriptors = AttachmentCustodyNative.openExportPair(",
                "Save try",
            ),
        ),
    }
    for label, fixture in mutations.items():
        try:
            validate(*fixture)
        except GuardFailure:
            continue
        raise GuardFailure(f"adversarial fixture unexpectedly passed: {label}")
    print(f"Android loader policy guard negative tests passed ({len(mutations)} mutations).")


def main(argv: list[str]) -> int:
    self_test_mode = argv[:1] == ["--self-test"]
    paths = argv[1:] if self_test_mode else argv
    if len(paths) != 3:
        print(
            "usage: attachment_native_viewer_policy_guard.py [--self-test] "
            "WORKFLOW NATIVE_ACCESS MAIN_ACTIVITY",
            file=sys.stderr,
        )
        return 2
    workflow, native_access, activity = (Path(path).read_text() for path in paths)
    try:
        if self_test_mode:
            self_test(workflow, native_access, activity)
        else:
            validate(workflow, native_access, activity)
    except GuardFailure as error:
        print(f"Android loader policy guard failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
