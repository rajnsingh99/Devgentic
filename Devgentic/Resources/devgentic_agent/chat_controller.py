from fastapi import APIRouter, HTTPException, Depends, Body
from fastapi.exceptions import RequestValidationError
from pydantic import ValidationError
from typing import List, Optional 
import sys
 # Corrected imports to use single dot for relative imports within the same package
from .api_models import (
    ChatRequest, ChatResponse,
    AddDocumentRequest, AddDocumentResponse,
    ServiceStatus, HealthCheckResponse
)
from .agent_service import agent_service
# The OLLAMA_MODEL import is kept as it's used in the root endpoint
from .config import OLLAMA_MODEL, EMBEDDING_MODEL_NAME, PID
# Removed import for memory_manager and the mem0 dummy user prefix
from .Utils.vectorstore_client import vector_store_manager
from .langchain_components import langchain_pipeline_manager


router = APIRouter()

async def check_service_readiness():
    status, msg = langchain_pipeline_manager.get_status()
    if status == "error": 
        detail_msg = msg or "Langchain pipeline or one of its critical components is not initialized. Check server logs."
        raise HTTPException(status_code=503, detail=detail_msg)

@router.get("/")
async def read_root():
    return {"message": "Devgentic Agent (Modular) is running.", "pid": PID, "initial_chat_model": OLLAMA_MODEL}

@router.post("/chat", response_model=ChatResponse)
async def chat_endpoint(
    payload: ChatRequest = Body(...), 
    _ready = Depends(check_service_readiness) 
):
    try:
        chat_response_obj = await agent_service.process_chat_interaction(payload)
        return chat_response_obj

    except ValueError as ve:
        raise HTTPException(status_code=400, detail=str(ve))
    except RuntimeError as e: 
        print(f"RuntimeError in /chat endpoint: {e}", file=sys.stderr)
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        print(f"Unexpected error in /chat endpoint: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail="An unexpected error occurred during chat processing.")


@router.post("/add_document", response_model=AddDocumentResponse)
async def add_document_endpoint(
    payload: AddDocumentRequest = Body(...)
):
    v_status, v_msg = vector_store_manager.get_status()
    if v_status == "error" or not vector_store_manager.vectorstore:
         raise HTTPException(status_code=503, detail=v_msg or "Vector store (ChromaDB) not initialized.")
    
    try:
        response = agent_service.add_document_to_vectorstore(payload)
        return response
    except ValueError as ve:
        raise HTTPException(status_code=400, detail=str(ve))
    except RuntimeError as e:
        print(f"RuntimeError in /add_document endpoint: {e}", file=sys.stderr)
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        print(f"Unexpected error in /add_document endpoint: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail="Failed to add document due to an unexpected error.")


@router.get("/health", response_model=HealthCheckResponse)
async def health_check_endpoint():
    service_details: List[ServiceStatus] = []
    overall_status_list = [] 

    lc_status, lc_msg = langchain_pipeline_manager.get_status()
    service_details.append(ServiceStatus(service="Langchain Pipeline", status=lc_status, message=lc_msg))
    overall_status_list.append(lc_status)

    # --- Mem0 Client health check has been removed ---

    vs_status, vs_msg = vector_store_manager.get_status()
    if vs_status == "ok" and vector_store_manager.vectorstore:
        try:
            vector_store_manager.vectorstore._collection.count() 
        except Exception as e:
            vs_status = "degraded"
            vs_msg = f"VectorStore initialized but health check call failed: {e}"
    # The conversation history is now also handled by ChromaDB, so this check covers both.
    service_details.append(ServiceStatus(service="VectorStore (ChromaDB)", status=vs_status, message=vs_msg))
    overall_status_list.append(vs_status)

    final_overall_status = "ok"
    if "error" in overall_status_list:
        final_overall_status = "error"
    elif "degraded" in overall_status_list:
        final_overall_status = "degraded"
            
    return HealthCheckResponse(
        overall_status=final_overall_status,
        chat_model=langchain_pipeline_manager.current_model_name,
        embedding_model=EMBEDDING_MODEL_NAME,
        pid=PID,
        services=service_details
    )