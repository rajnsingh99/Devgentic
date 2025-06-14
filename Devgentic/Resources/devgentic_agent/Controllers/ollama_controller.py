from fastapi import APIRouter, Body, HTTPException
from ..Models.ollama_models import OllamaChatRequest, AddDocumentRequest, AddDocumentResponse
from ..Models.common_models import GeneralChatResponse
from ..Services.ollama_service import ollama_service

router = APIRouter()

@router.post("/chat", response_model=GeneralChatResponse)
async def ollama_chat_endpoint(payload: OllamaChatRequest = Body(...)):
    """
    Endpoint for handling RAG and standard chat with local Ollama models.
    """
    try:
        response = await ollama_service.process_chat_interaction(payload)
        return response
    except Exception as e:
        # A more specific error handling block
        print(f"Error in /ollama/chat endpoint: {e}")
        raise HTTPException(status_code=500, detail=f"An internal server error occurred: {e}")

@router.post("/add_document", response_model=AddDocumentResponse)
async def add_document_endpoint(payload: AddDocumentRequest = Body(...)):
    """
    Endpoint for adding a document to the vector store for RAG.
    """
    try:
        response = ollama_service.add_document_to_vectorstore(payload)
        return response
    except RuntimeError as e:
        print(f"Error in /ollama/add_document endpoint: {e}")
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        print(f"An unexpected error occurred in /ollama/add_document: {e}")
        raise HTTPException(status_code=500, detail="An unexpected error occurred.")
