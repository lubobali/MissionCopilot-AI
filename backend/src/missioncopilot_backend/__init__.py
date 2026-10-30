def main() -> None:
    import uvicorn

    # Local dev only: bind to this machine, never 0.0.0.0. Port 8110 keeps clear of LuBot.
    uvicorn.run("missioncopilot_backend.app:app", host="127.0.0.1", port=8110)
