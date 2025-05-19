#
#  agent_launcher.py
#  Devgentic
#
#  Created by Raj Singh on 19/05/25.
#

# agent_launcher.py
import uvicorn
from fastapi import FastAPI
from langchain_ollama.chat_models import ChatOllama
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
import os
import sys
import signal # For handling termination signals gracefully

# --- Configuration ---
DEFAULT_MODEL_NAME = "gemma:2b"
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", DEFAULT_MODEL_NAME)
HOST = os.getenv("DEVGENTIC_AGENT_HOST", "127.0.0.1")
PORT = int(os.getenv("DEVGENTIC_AGENT_PORT", "8000"))
PID = os.getpid() # Get current process ID

# --- FastAPI App Initialization ---
app = FastAPI(
    title="Devgentic Agent",
    description="A FastAPI-backed Langchain agent using Ollama.",
    version="0.1.0",
)

# --- Langchain Setup ---
llm = None
chain = None
langchain_init_error = None

try:
    llm = ChatOllama(model=OLLAMA_MODEL)
    prompt = ChatPromptTemplate.from_messages([
        ("system", "You are a helpful AI assistant. Answer the user's questions to the best of your ability."),
        ("user", "{input}")
    ])
    chain = prompt | llm | StrOutputParser()
except Exception as e:
    langchain_init_error = f"Error initializing Langchain components: {e}"
    print(langchain_init_error, file=sys.stderr)


# --- API Endpoints ---
@app.get("/")
async def read_root():
    return {"message": "Devgentic Agent is running.", "pid": PID, "model": OLLAMA_MODEL}

@app.post("/chat")
async def chat_endpoint(user_input: dict):
    if langchain_init_error or not chain:
        return {"error": langchain_init_error or "Langchain agent not initialized properly. Check server logs."}
    
    query = user_input.get("input")
    if not query:
        return {"error": "Missing 'input' field in request."}

    try:
        response = await chain.ainvoke({"input": query})
        return {"response": response}
    except Exception as e:
        print(f"Error during agent invocation: {e}", file=sys.stderr)
        return {"error": f"An error occurred: {str(e)}"}

@app.get("/health")
async def health_check():
    if langchain_init_error:
         return {"status": "error", "model": OLLAMA_MODEL, "message": langchain_init_error, "pid": PID}
    if llm and chain:
        try:
            # A light check, like trying to get model info or a very short invoke
            # For now, we assume if it initialized, it's somewhat healthy.
            # A more robust check would involve a quick interaction with Ollama.
            return {"status": "ok", "model": OLLAMA_MODEL, "message": "Agent appears healthy.", "pid": PID}
        except Exception as e:
            print(f"Health check LLM interaction failed: {e}", file=sys.stderr)
            return {"status": "degraded", "model": OLLAMA_MODEL, "message": f"Agent is running, but LLM interaction might be impaired: {str(e)}", "pid": PID}
    else:
        return {"status": "error", "model": OLLAMA_MODEL, "message": "Langchain components not initialized.", "pid": PID}

# --- Graceful Shutdown Handling ---
def shutdown_signal_handler(signum, frame):
    print(f"Received signal {signum}. Shutting down Devgentic Agent (PID: {PID})...", file=sys.stdout)
    # Here you could add any cleanup tasks before exiting
    # For Uvicorn, it often handles SIGINT/SIGTERM itself to stop the server.
    # If you have other resources, clean them up here.
    sys.exit(0)

signal.signal(signal.SIGINT, shutdown_signal_handler)  # Handle Ctrl+C
signal.signal(signal.SIGTERM, shutdown_signal_handler) # Handle termination signal

# --- Main Execution ---
if __name__ == "__main__":
    print(f"Starting Devgentic Agent (PID: {PID}) with model: {OLLAMA_MODEL}", file=sys.stdout)
    print(f"Agent PID: {PID}", file=sys.stdout) # Print PID
    print(f"Agent running on: http://{HOST}:{PORT}", file=sys.stdout) # Print URL
    sys.stdout.flush()

    uvicorn.run(app, host=HOST, port=PORT)
