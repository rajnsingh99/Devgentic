# devgentic_agent/controllers/chat_controller.py
from fastapi import APIRouter, HTTPException, Depends, Body
from fastapi.exceptions import RequestValidationError
from pydantic import ValidationError
from typing import List, Optional # Added Optional
import sys

from ..models.api_models import (
    ChatRequest, ChatResponse, # Updated models
    AddDocumentRequest, AddDocumentResponse,
    ServiceStatus, HealthCheckResponse
)
from ..services.agent_service import agent_service 
from ..config import OLLAMA_MODEL, EMBEDDING_MODEL_NAME, PID, HEALTH_CHECK_MEM0_DUMMY_USER_PREFIX

from ..tools.memory_client import memory_manager
from ..tools.vectorstore_client import vector_store_manager
from ..tools.langchain_components import langchain_pipeline_manager


router = APIRouter()

async def check_service_readiness():
    status, msg = langchain_pipeline_manager.get_status()
    # Agent is considered not ready if status is 'error'
    if status == "error": 
        detail_msg = msg or "Langchain pipeline or one of its critical components is not initialized. Check server logs."
        raise HTTPException(status_code=503, detail=detail_msg)
    # If status is 'degraded', the service might still partially function, so we don't raise 503 here by default.
    # Specific endpoints can decide if 'degraded' is acceptable.

@router.get("/")
async def read_root():
    return {"message": "Devgentic Agent (Modular) is running.", "pid": PID, "initial_chat_model": OLLAMA_MODEL}

@router.post("/chat", response_model=ChatResponse)
async def chat_endpoint(
    # Use Body(...) to ensure payload is read from request body
    payload: ChatRequest = Body(...), 
    _ready = Depends(check_service_readiness) 
):
    """
    Endpoint to interact with the chat agent.
    Requires a JSON payload conforming to the ChatRequest model.
    """
    try:
        # The agent_service.process_chat_interaction now directly returns a ChatResponse Pydantic model
        # or raises a RuntimeError which we catch below.
        # The service layer's process_chat_interaction is expected to handle
        # the client_notification_message internally if the ChatResponse model is updated.
        # Let's assume the service method returns a tuple: (ai_response_content, conversation_id, client_notification_message)
        # Or, more cleanly, the ChatResponse model from the service already includes the notification.
        # Based on the last update to agent_service, it returns a ChatResponse object.
        # We need to ensure that the ChatResponse object from the service includes the notification.

        # The service method `process_chat_interaction` in agent_service_py_updated_v4 returns a ChatResponse.
        # However, it doesn't explicitly populate the `notification` field in that ChatResponse.
        # The `_handle_model_change_and_get_summary` returns `client_error_message` which should be
        # put into the `notification` field of the final `ChatResponse`.

        # Let's adjust to how agent_service.py (agent_service_py_updated_v4) is structured:
        # It returns a ChatResponse, but the client_notification_message is logged, not added to ChatResponse there.
        # We need to capture it from the service or have the service return it.
        # For now, let's assume the service's process_chat_interaction is modified to return a tuple
        # (ai_response: str, conversation_id: str, notification: Optional[str])
        # OR the ChatResponse object it returns is already populated with the notification.
        #
        # Re-checking agent_service_py_updated_v4:
        # `_handle_model_change_and_get_summary` returns `(effective_prompt, client_error_message)`
        # `process_chat_interaction` calls it and gets `client_notification_message`.
        # Then it does: `return ChatResponse(response=ai_response_content, conversation_id=conversation_id)`
        # It *does not* add `client_notification_message` to this `ChatResponse`.
        #
        # This controller needs to get that notification.
        # Simplest change for now: Modify `process_chat_interaction` to return the notification as well.
        # OR, update ChatResponse within `process_chat_interaction`.
        # Let's assume for this step that `process_chat_interaction` will be internally modified
        # to return a ChatResponse object that *includes* the notification if present.
        # If not, the controller would need to get it separately.
        #
        # For now, let's call it and if the service is updated as per my thoughts, it works.
        # If the service ISN'T updated to put notification in ChatResponse, this will be an issue.
        #
        # Let's assume the `agent_service.process_chat_interaction` is updated like this:
        # In agent_service.py, inside process_chat_interaction, before returning:
        # response_data = {"response": ai_response_content, "conversation_id": conversation_id}
        # if client_notification_message:
        #     response_data["notification"] = client_notification_message
        # return ChatResponse(**response_data)
        # With this assumption, the controller code is simpler:

        chat_response_obj = await agent_service.process_chat_interaction(payload)
        return chat_response_obj # This object should now have the .notification field populated by the service

    except ValueError as ve: # Catch Pydantic validation errors or other ValueErrors
        # Pydantic's RequestValidationError is more specific for request body validation
        # but a general ValueError might come from our custom validators or logic.
        raise HTTPException(status_code=400, detail=str(ve))
    except RuntimeError as e: 
        print(f"RuntimeError in /chat endpoint: {e}", file=sys.stderr)
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        print(f"Unexpected error in /chat endpoint: {e}", file=sys.stderr)
        # Log the full error for debugging
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

    mem0_status, mem0_msg = memory_manager.get_status()
    if mem0_status == "ok":
        try:
            memory_manager.get_all_memories(user_id=f"{HEALTH_CHECK_MEM0_DUMMY_USER_PREFIX}{PID}", limit=1)
        except Exception as e:
            mem0_status = "degraded"
            mem0_msg = f"Mem0 client initialized but health check call failed: {e}"
    service_details.append(ServiceStatus(service="Mem0 Client", status=mem0_status, message=mem0_msg))
    if mem0_status != "disabled": 
        overall_status_list.append(mem0_status)

    vs_status, vs_msg = vector_store_manager.get_status()
    if vs_status == "ok" and vector_store_manager.vectorstore:
        try:
            vector_store_manager.vectorstore._collection.count() 
        except Exception as e:
            vs_status = "degraded"
            vs_msg = f"VectorStore initialized but health check call failed: {e}"
    service_details.append(ServiceStatus(service="VectorStore (ChromaDB)", status=vs_status, message=vs_msg))
    overall_status_list.append(vs_status)

    final_overall_status = "ok"
    if "error" in overall_status_list:
        final_overall_status = "error"
    elif "degraded" in overall_status_list:
        final_overall_status = "degraded"
            
    return HealthCheckResponse(
        overall_status=final_overall_status,
        chat_model=langchain_pipeline_manager.current_model_name, # Get current model from manager
        embedding_model=EMBEDDING_MODEL_NAME,
        pid=PID,
        services=service_details
    )
