import uvicorn
from fastapi import FastAPI
import signal
import sys
import os

# Import configurations and print summary
from .config import (
    HOST, PORT, PID, AGENT_VERSION,
    APP_TITLE, APP_DESCRIPTION, print_config_summary
)

# Import the API router from controllers
from . import chat_controller

# --- FastAPI App Initialization ---
# Ensure that tool managers are initialized when their modules are imported.
# This happens when `services.agent_service` and `controllers.chat_controller` are imported,
# as they import from the `tools` package.

app = FastAPI(
    title=APP_TITLE,
    description=APP_DESCRIPTION,
    version=AGENT_VERSION,
)

# Include API routers
app.include_router(chat_controller.router, prefix="/agent", tags=["Agent"]) # Added a prefix for clarity

# --- Graceful Shutdown Handling ---
# Store the original signal handlers
original_sigint_handler = signal.getsignal(signal.SIGINT)
original_sigterm_handler = signal.getsignal(signal.SIGTERM)

def shutdown_signal_handler(signum, frame):
    print(f"\nReceived signal {signal.Signals(signum).name}. Shutting down Devgentic Agent (PID: {PID})...", file=sys.stdout, flush=True)
    
    # Perform any application-specific cleanup here
    # For example, explicitly closing any open resources if necessary.
    # Most modern libraries handle this well, but good to have a place for it.
    print("Devgentic Agent shutdown complete.", file=sys.stdout, flush=True)

    # Restore original handlers and re-raise the signal if Uvicorn needs to handle it
    # Or simply exit if Uvicorn's own handling isn't required after your cleanup.
    # For Uvicorn, it's often best to let it handle the final exit after your cleanup.
    if signum == signal.SIGINT:
        if callable(original_sigint_handler):
            original_sigint_handler(signum, frame)
        else: # If original was SIG_DFL or SIG_IGN
            sys.exit(0) # Default exit for SIGINT if no specific handler
    elif signum == signal.SIGTERM:
        if callable(original_sigterm_handler):
            original_sigterm_handler(signum, frame)
        else:
            sys.exit(0) # Default exit for SIGTERM

# Set custom signal handlers
signal.signal(signal.SIGINT, shutdown_signal_handler)
signal.signal(signal.SIGTERM, shutdown_signal_handler)


# --- Main Execution ---
if __name__ == "__main__":
    # Print configuration summary at startup
    print_config_summary()
    
    # Check for initialization errors from key components (optional, for early feedback)
    # These are already printed by the components themselves, but a summary here could be useful.
    # from .tools.langchain_components import langchain_pipeline_manager
    # if langchain_pipeline_manager.initialization_error:
    #     print("--- Critical Initialization Errors Detected ---", file=sys.stderr)
    #     print(langchain_pipeline_manager.initialization_error, file=sys.stderr)
    #     print("--- Agent may not function correctly ---", file=sys.stderr)
    # # Similar checks for memory_manager and vector_store_manager if desired

    sys.stdout.flush()
    sys.stderr.flush()

    # Run Uvicorn server
    # Note: Uvicorn's `run` function is blocking.
    # The reload=True option is useful for development.
    # In production, you might run Uvicorn with Gunicorn or another process manager.
    # The 'app' variable should be a string 'module:app_instance' when Uvicorn is run from CLI.
    # When run programmatically like this, passing the app instance directly is fine.
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")

# To run this application:
# 1. Ensure all dependencies are installed:
#    pip install fastapi uvicorn langchain-ollama langchain-community mem0-py chromadb pydantic sentence-transformers
# 2. Set environment variables (MEM0_API_KEY, OLLAMA_MODEL, etc.) as needed.
# 3. Navigate to the directory *containing* the `devgentic_agent` folder.
# 4. Run using Python: `python -m devgentic_agent.main`
#    (This assumes your `devgentic_agent` folder is in your PYTHONPATH or current working directory)
#
# Alternatively, from within the `devgentic_agent` directory, you might need to adjust imports
# or run with `python main.py` if your PYTHONPATH is set up to include the parent.
# The `python -m` approach is generally more robust for package structures.
