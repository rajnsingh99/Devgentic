# filename: main.py
import uvicorn
from fastapi import FastAPI
from .config import HOST, PORT, APP_TITLE, APP_DESCRIPTION, APP_VERSION, print_config_summary

# Import the modular controllers
from .Controllers import ollama_controller
from .Controllers import remote_controller
from .Controllers import agent_controller
from .Controllers import utility_controller # Added

app = FastAPI(
    title=APP_TITLE,
    description=APP_DESCRIPTION,
    version=APP_VERSION,
)

# --- Include API Routers for each provider ---
# Each router now has a distinct prefix, creating clean endpoint separation
app.include_router(ollama_controller.router, prefix="/ollama", tags=["Ollama (Local RAG)"])
app.include_router(remote_controller.router, prefix="/remote", tags=["Remote Providers (GPT/Gemini)"])
app.include_router(agent_controller.router, prefix="/agent", tags=["Agentic Workflow"])
app.include_router(utility_controller.router, prefix="/utils", tags=["Utilities"]) # Added

@app.get("/", tags=["Root"])
async def read_root():
    return {"message": "Devgentic Multi-Provider Chat Backend is running."}


if __name__ == "__main__":
    print_config_summary()
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")

