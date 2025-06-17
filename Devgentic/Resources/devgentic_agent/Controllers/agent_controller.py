# filename: Controllers/agent_controller.py
from fastapi import APIRouter, Body, HTTPException
from ..Models.agent_models import AgentOrchestrationRequest
from ..Models.common_models import GeneralChatResponse
from ..Services.agent_service import agent_service

router = APIRouter()

@router.post("/orchestrate", response_model=GeneralChatResponse)
async def agent_orchestrate_endpoint(
    payload: AgentOrchestrationRequest = Body(...)
):
    """
    Endpoint for executing a complex task using a configured hierarchy of agents.
    """
    try:
        response = await agent_service.process_chat_interaction(payload)
        return response
    except ValueError as ve:
        # Catch validation errors, e.g., misconfigured agent hierarchy
        raise HTTPException(status_code=400, detail=str(ve))
    except RuntimeError as e:
        # Catch service-level errors, e.g., could not pull from LangChain Hub
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        # Catch any other unexpected errors during orchestration
        print(f"An unexpected error occurred in /agent/orchestrate: {e}")
        raise HTTPException(status_code=500, detail="An unexpected internal server error occurred during agent orchestration.")

