"""Unified command-line entry point for collector services."""

from __future__ import annotations

import argparse


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="ustc-assistant")
    commands = parser.add_subparsers(dest="command", required=True)

    collect = commands.add_parser("collect")
    collect_sources = collect.add_subparsers(dest="source", required=True)
    collect_sources.add_parser("jw")
    collect_sources.add_parser("young-enrolment")
    collect_sources.add_parser("young-schedule")

    query = commands.add_parser("query")
    query_sources = query.add_subparsers(dest="source", required=True)
    icourse = query_sources.add_parser("icourse")
    modes = icourse.add_mutually_exclusive_group(required=True)
    modes.add_argument("--course")
    modes.add_argument("--teacher")
    modes.add_argument("--jw-bundle")
    return parser


def main(argv: list[str] | None = None) -> int:
    build_parser().parse_args(argv)
    return 1
