import asyncio, sys
host = sys.argv[1]
async def probe(port, sem):
    async with sem:
        try:
            r, w = await asyncio.wait_for(asyncio.open_connection(host, port), 1.5)
            w.close(); return port
        except Exception:
            return None
async def main():
    sem = asyncio.Semaphore(800)
    res = await asyncio.gather(*(probe(p, sem) for p in range(1, 65536)))
    open_ports = sorted(p for p in res if p)
    print(f"scanned 65535 TCP ports on {host} from a separate machine on the same network")
    print("open:", open_ports)
    for p, name in [(22,'ssh'),(80,'http'),(1883,'mqtt plaintext'),(2019,'caddy admin'),(2375,'docker api'),(2376,'docker api tls'),(5432,'postgresql'),(8000,'api internal'),(8001,'ingest internal'),(9001,'mqtt websockets')]:
        print(f"  {p:<5} {name:<16} {'OPEN' if p in open_ports else 'closed'}")
    sys.exit(0 if open_ports == [443, 8883] else 1)
asyncio.run(main())
