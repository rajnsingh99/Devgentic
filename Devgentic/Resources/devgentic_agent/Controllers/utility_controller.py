# filename: Controllers/utility_controller.py
from fastapi import APIRouter, HTTPException, Query, Header, Response, status
from typing import List, Annotated, Optional

from ..Models.utility_models import ModelDetail, HealthCheckResponse, ServiceStatus
from ..Services.utility_service import utility_service
from ..Utils.conversation_storage_manager import conversation_storage_manager
from ..Utils.vectorstore_client import vector_store_manager
# Import the MCP tool manager to trigger the refresh
from ..Utils.mcp_tool_manager import mcp_tool_manager

router = APIRouter()


@router.post("/refresh_tools", status_code=status.HTTP_204_NO_CONTENT)
async def refresh_tools_endpoint():
    """
    Triggers a hot-reload of the tool configuration from the mcp_servers.json file.
    This allows adding new MCP servers and tools without restarting the backend.
    """
    try:
        print("[UtilityController] Refresh request received. Reloading tools...")
        mcp_tool_manager.load_and_register_tools()
        # Return a 204 No Content response on success, as is standard for such actions
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    except Exception as e:
        print(f"An unexpected error occurred during tool refresh: {e}")
        raise HTTPException(status_code=500, detail="An error occurred while refreshing the tool configuration.")


@router.get("/list_models", response_model=List[ModelDetail])
async def list_models_endpoint(
        provider: str = Query(..., description="The remote provider to query (e.g., 'openai', 'google')."),
        category: Optional[str] = Query(None,
                                        description="An optional category to filter models by (e.g., 'pro', 'flash')."),
        x_api_key: Annotated[str, Header(..., description="The API key for the provider.")] = ""
):
    """
    Fetches a list of currently available models from the specified remote provider.
    """
    if not x_api_key:
        raise HTTPException(status_code=400, detail="API key must be provided in the 'X-API-Key' header.")
    try:
        models = utility_service.list_remote_models(provider, x_api_key, category)
        return models
    except ValueError as ve:
        raise HTTPException(status_code=400, detail=str(ve))
    except RuntimeError as re:
        raise HTTPException(status_code=503, detail=str(re))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"An unexpected error occurred: {e}")


@router.get("/health_check", response_model=HealthCheckResponse)
async def health_check_endpoint():
    """
    Performs a health check on critical backend services like vector stores.
    """
    service_details: List[ServiceStatus] = []

    # Check RAG Vector Store
    vs_status, vs_msg = vector_store_manager.get_status()
    service_details.append(ServiceStatus(service="VectorStore (RAG)", status=vs_status, message=vs_msg))

    # Check History Vector Store
    cs_status, cs_msg = conversation_storage_manager.is_available()
    service_details.append(ServiceStatus(service="VectorStore (History)", status=cs_status, message=cs_msg))

    overall_status: Literal["ok", "degraded", "error"] = "ok"
    if any(s.status == "error" for s in service_details):
        overall_status = "error"
    elif any(s.status == "degraded" for s in service_details):
        overall_status = "degraded"

    return HealthCheckResponse(
        overall_status=overall_status,
        services=service_details
    )
