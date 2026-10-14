#!/usr/bin/env python3
"""Load an explicit restricted credential before starting the single worker."""
import argparse
import os
import stat


def read_token(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError("token must be an owner-only regular file owned by the service UID")
        data = stream.read(4097)
        if len(data) > 4096:
            raise ValueError("token file exceeds limit")
    token = data.decode("ascii").strip()
    if len(token) < 32 or any(c.isspace() for c in token):
        raise ValueError("token requires at least 32 non-whitespace ASCII characters")
    return token


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--model-directory", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8793)
    args = parser.parse_args()
    os.environ["MISTT_CONVERSATION_TOKEN"] = read_token(args.token_file)
    os.environ["MISTT_CONVERSATION_MODEL"] = args.model_directory
    import uvicorn
    uvicorn.run("server:app", host=args.host, port=args.port, workers=1,
                access_log=False, log_level="warning", timeout_keep_alive=5,
                timeout_graceful_shutdown=20)


if __name__ == "__main__":
    main()
