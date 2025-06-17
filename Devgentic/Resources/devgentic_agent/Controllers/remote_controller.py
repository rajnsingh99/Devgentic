# filename: Controllers/remote_controller.py
from fastapi import APIRouter, Body, HTTPException
from ..Models.remote_models import RemoteChatRequest
from ..Models.common_models import GeneralChatResponse
from ..Services.remote_service import remote_service

router = APIRouter()

@router.post("/chat", response_model=GeneralChatResponse)
async def remote_chat_endpoint(
    payload: RemoteChatRequest = Body(...)
):
    """
    Endpoint for routing chat requests to external providers like OpenAI, Google, or Anthropic.
    """
    try:
        response = await remote_service.process_chat_interaction(payload)
        return response
    except RuntimeError as e:
        # Catch specific runtime errors from the service (e.g., API key issues, model not found)
        print(f"Service-level error in /remote/chat: {e}")
        # Return a 503 Service Unavailable, as the external service may be down or misconfigured
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        # Catch any other unexpected errors
        print(f"An unexpected error occurred in /remote/chat: {e}")
        raise HTTPException(status_code=500, detail="An unexpected internal server error occurred.")
