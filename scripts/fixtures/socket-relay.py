#!/usr/bin/env python3
"""socket-relay.py SOCKET=HOST:PORT [...] — serves each Unix socket path and relays every
connection to the TCP address after it, both ways, until killed.

The socket-connection tests use it to put the MariaDB and PostgreSQL containers behind
local Unix sockets (Docker Desktop cannot share a container's own socket with macOS).
The database drivers speak the same protocol over a socket as over TCP, so the app's
socket code path runs for real: the MySQL client opens the socket file it is given,
libpq opens <directory>/.s.PGSQL.<port>."""
import asyncio
import os
import sys


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


def handler(host, port):
    async def handle(client_reader, client_writer):
        try:
            server_reader, server_writer = await asyncio.open_connection(host, port)
        except OSError:
            client_writer.close()
            return
        await asyncio.gather(pipe(client_reader, server_writer), pipe(server_reader, client_writer))
    return handle


async def main(specs):
    servers = []
    for spec in specs:
        path, target = spec.split("=", 1)
        host, port = target.rsplit(":", 1)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.exists(path):
            os.unlink(path)
        servers.append(await asyncio.start_unix_server(handler(host, int(port)), path=path))
        print(f"relaying {path} -> {host}:{port}", flush=True)
    await asyncio.gather(*(s.serve_forever() for s in servers))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    asyncio.run(main(sys.argv[1:]))
