# devgentic_agent/controllers/chat_controller.py
from fastapi import APIRouter, HTTPException, Depends
from typing import List

from ..models.api_models import (
    ChatRequest, ChatResponse,
    AddDocumentRequest, AddDocumentResponse,
    ServiceStatus, HealthCheckResponse
)
from ..services.agent_service import agent_service # Import the service instance
from ..config import OLLAMA_MODEL, EMBEDDING_MODEL_NAME, PID, HEALTH_CHECK_MEM0_DUMMY_USER_PREFIX

# Import tool managers for health check status
from ..tools.memory_client import memory_manager
from ..tools.vectorstore_client import vector_store_manager
from ..tools.langchain_components import langchain_pipeline_manager


router = APIRouter()

# --- Dependency to check service readiness ---
async def check_service_readiness():
    """
    A dependency that checks if the core langchain pipeline is ready.
    If not, it raises an HTTPException.
    """
    # More robust check would be to see if langchain_pipeline_manager.chain is None
    # or if its get_status() indicates an error.
    status, msg = langchain_pipeline_manager.get_status()
    if status == "error" or not langchain_pipeline_manager.chain :
        detail_msg = msg or "Langchain pipeline or one of its critical components is not initialized. Check server logs."
        raise HTTPException(status_code=503, detail=detail_msg)
    # You could add checks for other critical services here if needed for all endpoints
    # For instance, if vector_store_manager is essential for all chat operations.

@router.get("/")
async def read_root():
    """
    Root endpoint providing basic agent information.
    """
    return {"message": "Devgentic Agent (Modular) is running.", "pid": PID, "chat_model": OLLAMA_MODEL}

@router.post("/chat", response_model=ChatResponse)
async def chat_endpoint(
    payload: ChatRequest,
    # Use Depends to ensure critical services are ready before processing
    # This check is now more specific to langchain_pipeline_manager
    _ready = Depends(check_service_readiness)
):
    """
    Endpoint to interact with the chat agent.
    Requires `user_prompt` and optionally `conversation_id`.
    """
    if not payload.user_prompt:
        raise HTTPException(status_code=400, detail="Missing 'user_prompt' field in request.")

    try:
        response = await agent_service.process_chat_interaction(payload)
        return response
    except RuntimeError as e: # Catch specific errors from the service layer
        # Log the full error server-side
        print(f"RuntimeError in /chat endpoint: {e}", file=sys.stderr)
        # Provide a generic error to the client or a more specific one if safe
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        # Catch-all for unexpected errors
        print(f"Unexpected error in /chat endpoint: {e}", file=sys.stderr)
        raise HTTPException(status_code=500, detail="An unexpected error occurred during chat processing.")


@router.post("/add_document", response_model=AddDocumentResponse)
async def add_document_endpoint(
    payload: AddDocumentRequest,
    # check_service_readiness could be used here too if adding docs relies on LLM components
    # For now, assume it primarily relies on vector_store_manager
):
    """
    Endpoint to add a new document to the vector store.
    Requires `text` and optionally `source` and `metadata`.
    """
    v_status, v_msg = vector_store_manager.get_status()
    if v_status == "error" or not vector_store_manager.vectorstore:
         raise HTTPException(status_code=503, detail=v_msg or "Vector store (ChromaDB) not initialized.")

    if not payload.text:
        raise HTTPException(status_code=400, detail="Missing 'text' field in request.")
    
    try:
        response = agent_service.add_document_to_vectorstore(payload)
        return response
    except RuntimeError as e:
        print(f"RuntimeError in /add_document endpoint: {e}", file=sys.stderr)
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        print(f"Unexpected error in /add_document endpoint: {e}", file=sys.stderr)
        raise HTTPException(status_code=500, detail="Failed to add document due to an unexpected error.")


@router.get("/health", response_model=HealthCheckResponse)
async def health_check_endpoint():
    """
    Provides a health check of the agent and its components.
    """
    service_details: List[ServiceStatus] = []
    overall_status_list = [] # To determine overall status

    # 1. Core Langchain Pipeline Status
    lc_status, lc_msg = langchain_pipeline_manager.get_status()
    service_details.append(ServiceStatus(service="Langchain Pipeline", status=lc_status, message=lc_msg))
    overall_status_list.append(lc_status)

    # 2. Mem0 Client Status
    mem0_status, mem0_msg = memory_manager.get_status()
    # For health check, try a light operation if status is 'ok'
    if mem0_status == "ok":
        try:
            # Simple check: try to get a non-existent user's history
            memory_manager.get_all_memories(user_id=f"{HEALTH_CHECK_MEM0_DUMMY_USER_PREFIX}{PID}", limit=1)
            # If no exception, it's responsive
        except Exception as e:
            mem0_status = "degraded"
            mem0_msg = f"Mem0 client initialized but health check call failed: {e}"
    service_details.append(ServiceStatus(service="Mem0 Client", status=mem0_status, message=mem0_msg))
    if mem0_status != "disabled": # Disabled services don't affect overall health negatively
        overall_status_list.append(mem0_status)


    # 3. Vector Store (ChromaDB) Status
    vs_status, vs_msg = vector_store_manager.get_status()
    # For health check, try a light operation if status is 'ok'
    if vs_status == "ok" and vector_store_manager.vectorstore:
        try:
            vector_store_manager.vectorstore._collection.count() # Access underlying collection count
        except Exception as e:
            vs_status = "degraded"
            vs_msg = f"VectorStore initialized but health check call failed: {e}"
    service_details.append(ServiceStatus(service="VectorStore (ChromaDB)", status=vs_status, message=vs_msg))
    overall_status_list.append(vs_status)

    # Determine overall status
    final_overall_status = "ok"
    if "error" in overall_status_list:
        final_overall_status = "error"
    elif "degraded" in overall_status_list:
        final_overall_status = "degraded"
            
    return HealthCheckResponse(
        overall_status=final_overall_status,
        chat_model=OLLAMA_MODEL,
        embedding_model=EMBEDDING_MODEL_NAME,
        pid=PID,
        services=service_details
    )
