def main() -> None:
    import uvicorn

    # Local dev only: bind to this machine, never 0.0.0.0. Port 8110 keeps clear of LuBot.
    # The factory checks every database before serving (server.build); it refuses to start without.
    uvicorn.run("missioncopilot_backend.server:build", factory=True, host="127.0.0.1", port=8110)
