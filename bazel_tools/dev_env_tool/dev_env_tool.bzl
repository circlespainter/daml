# Copyright (c) 2019 The DAML Authors. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

load("@bazel_tools//tools/cpp:lib_cc_configure.bzl", "get_cpu_value")

def _create_build_content(rule_name, tools, win_paths, nix_paths):
    content = """
# DO NOT EDIT: automatically generated BUILD file for dev_env_tool.bzl: {rule_name}
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "all",
    srcs = glob(["**"]),
)
        """.format(rule_name = rule_name)

    for i in range(0, len(tools)):
        content += """
filegroup(
    name = "{tool}",
    srcs = select({{
        ":windows": ["{win_path}"],
        "//conditions:default": ["{nix_path}"],
    }}),
)
            """.format(
            tool = tools[i],
            win_path = win_paths[i],
            nix_path = nix_paths[i],
        )

    content += """
config_setting(
    name = "windows",
    values = {"cpu": "x64_windows"},
    visibility = ["//visibility:private"],
)
"""

    return content

def _dadew_where(ctx, ps):
    ps = ctx.which("powershell")
    ps_result = ctx.execute([ps, "-Command", "dadew where"], quiet = True)

    if ps_result.return_code != 0:
        fail("Failed to obtain dadew location.\nExit code %d.\n%s\n%s" %
             (ps_result.return_code, ps_result.stdout, ps_result.stderr))

    return ps_result.stdout.splitlines()[0]

def _dadew_tool_home(dadew, tool):
    return "%s\\scoop\\apps\%s\\current" % (dadew, tool)

def _find_files_recursive(ctx, find, root):
    find_result = ctx.execute([find, "-L", root, "-type", "f", "-print0"])

    if find_result.return_code != 0:
        fail("Failed to list files contained in '%s':\nExit code %d\n%s\n%s." %
             (root, find_result.return_code, find_result.stdout, find_result.stderr))

    return [
        f[len(root) + 1:]
        for f in find_result.stdout.split("\0")
        if f and f.startswith(root)
    ]

def _symlink_files_recursive(ctx, find, source, dest):
    files = _find_files_recursive(ctx, find, source)
    for f in files:
        ctx.symlink("%s/%s" % (source, f), "%s/%s" % (dest, f))

def _dev_env_tool_impl(ctx):
    if get_cpu_value(ctx) == "x64_windows":
        ps = ctx.which("powershell")
        dadew = _dadew_where(ctx, ps)
        find = _dadew_tool_home(dadew, "msys2") + "\\usr\\bin\\find.exe"
        tool_home = _dadew_tool_home(dadew, ctx.attr.win_tool)
        for i in ctx.attr.win_include:
            src = "%s\%s" % (tool_home, i)
            dst = ctx.attr.win_include_as.get(i, i)
            if ctx.attr.prefix:
                dst = "%s\%s" % (ctx.attr.prefix, dst)
            _symlink_files_recursive(ctx, find, src, dst)
    else:
        find = "find"
        tool_home = "../%s" % ctx.attr.nix_label.name
        for i in ctx.attr.nix_include:
            src = "%s/%s" % (tool_home, i)
            dst = i
            if ctx.attr.prefix:
                dst = "%s/%s" % (ctx.attr.prefix, dst)
            _symlink_files_recursive(ctx, find, src, dst)

    build_path = ctx.path("BUILD")
    build_content = _create_build_content(
        rule_name = ctx.name,
        tools = ctx.attr.tools,
        win_paths = [
            "%s/%s" % (ctx.attr.prefix, path)
            for path in ctx.attr.win_paths
        ] if ctx.attr.prefix else ctx.attr.win_paths,
        nix_paths = [
            "%s/%s" % (ctx.attr.prefix, path)
            for path in ctx.attr.nix_paths
        ] if ctx.attr.prefix else ctx.attr.nix_paths,
    )
    ctx.file(build_path, content = build_content, executable = False)

dev_env_tool = repository_rule(
    implementation = _dev_env_tool_impl,
    attrs = {
        "tools": attr.string_list(
            mandatory = True,
        ),
        "win_tool": attr.string(
            mandatory = True,
        ),
        "win_include": attr.string_list(
            mandatory = True,
        ),
        "win_include_as": attr.string_dict(
            mandatory = False,
            default = {},
        ),
        "win_paths": attr.string_list(
            mandatory = False,
        ),
        "nix_label": attr.label(
            mandatory = False,
        ),
        "nix_include": attr.string_list(
            mandatory = True,
        ),
        "nix_paths": attr.string_list(
            mandatory = True,
        ),
        "prefix": attr.string(),
    },
    configure = True,
    local = True,
)
