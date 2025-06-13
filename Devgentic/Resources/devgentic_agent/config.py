import os

# --- General Agent Configuration ---
DEFAULT_MODEL_NAME: str = "gemma:7b" 
OLLAMA_MODEL: str = os.getenv("OLLAMA_MODEL", DEFAULT_MODEL_NAME)
OLLAMA_BASE_URL: str = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")

HOST: str = os.getenv("DEVGENTIC_AGENT_HOST", "127.0.0.1")
PORT: int = int(os.getenv("DEVGENTIC_AGENT_PORT", "8000"))
AGENT_VERSION: str = "0.3.0" 

# --- ChromaDB and Embeddings Configuration ---
CHROMA_PERSIST_DIRECTORY: str = os.getenv("CHROMA_PERSIST_DIRECTORY", "./chroma_db_store")
EMBEDDING_MODEL_NAME: str = os.getenv("EMBEDDING_MODEL_NAME", OLLAMA_MODEL) 
CHROMA_COLLECTION_NAME: str = "devgentic_agent_store"

# --- Logging and Process ID ---
PID: int = os.getpid()

# --- Application Metadata ---
APP_TITLE: str = "Devgentic Agent (Modular)"
APP_DESCRIPTION: str = (
    "A FastAPI-backed Langchain agent using Ollama, "
    "with ChromaDB for RAG and conversation history. (Modularized Structure)"
)

def print_config_summary():
    """Prints a summary of the loaded configuration."""
    print("--- Devgentic Agent Configuration Summary ---", flush=True)
    print(f"Agent Version: {AGENT_VERSION}", flush=True)
    print(f"Process ID (PID): {PID}", flush=True)
    print(f"Initial Default Chat Model (OLLAMA_MODEL): {OLLAMA_MODEL}", flush=True)
    print(f"Initial Default Ollama Base URL (OLLAMA_BASE_URL): {OLLAMA_BASE_URL}", flush=True)
    print(f"Embedding Model (EMBEDDING_MODEL_NAME): {EMBEDDING_MODEL_NAME}", flush=True)
    print(f"Conversation History Backend: ChromaDB", flush=True)
    print(f"ChromaDB Persist Dir: {CHROMA_PERSIST_DIRECTORY}", flush=True)
    print(f"ChromaDB Collection: {CHROMA_COLLECTION_NAME}", flush=True)
    print(f"Agent Host: {HOST}", flush=True)
    print(f"Agent Port: {PORT}", flush=True)
    print("--- End Configuration Summary ---", flush=True)