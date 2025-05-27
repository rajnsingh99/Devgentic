# devgentic_agent/tools/langchain_components.py
import sys
from typing import Optional, Dict, Any, List
from langchain_ollama.chat_models import ChatOllama
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import RunnablePassthrough, RunnableLambda, RunnableSerializable

from ..config import OLLAMA_MODEL, OLLAMA_BASE_URL
# Import helper functions and managers from sibling tool modules
from .memory_client import memory_manager, format_mem0_history_for_prompt, Mem0MemoryType
from .vectorstore_client import vector_store_manager, format_chroma_context_for_prompt

class LangchainPipelineManager:
    """
    Manages the Langchain LLM, prompt, and the main processing chain.
    """
    def __init__(self):
        self.llm: Optional[ChatOllama] = None
        self.prompt_template: Optional[ChatPromptTemplate] = None
        self.chain: Optional[RunnableSerializable[Dict, str]] = None # Type hint for the chain
        self.initialization_error: Optional[str] = None
        self._initialize_components()

    def _get_chat_history_from_mem0(self, inputs: Dict[str, Any]) -> str:
        """Retrieves and formats chat history from Mem0 for the chain."""
        conversation_id = inputs.get("conversation_id")
        if not memory_manager.client or not conversation_id:
            return "Chat history not available (Mem0 not configured or no conversation_id)."
        
        # Retrieve memories (Mem0's get_all usually returns newest first)
        raw_history_memories: List[Mem0MemoryType] = memory_manager.get_all_memories(user_id=conversation_id, limit=10)
        if raw_history_memories:
            raw_history_memories.reverse() # Reverse to get chronological order for the prompt
        return format_mem0_history_for_prompt(raw_history_memories)

    def _get_context_from_chroma(self, inputs: Dict[str, Any]) -> str:
        """Retrieves context from ChromaDB based on user_prompt for the chain."""
        user_prompt = inputs.get("user_prompt")
        if not vector_store_manager.retriever or not user_prompt:
            return "Context retrieval not available (ChromaDB not configured or no user_prompt)."
        
        docs = vector_store_manager.retrieve_documents(query=user_prompt)
        return format_chroma_context_for_prompt(docs)

    def _initialize_components(self):
        """Initializes LLM, prompt, and the main chain."""
        current_errors: List[str] = []

        # 1. Initialize LLM
        try:
            self.llm = ChatOllama(model=OLLAMA_MODEL, base_url=OLLAMA_BASE_URL)
            print(f"ChatOllama LLM initialized with model: {OLLAMA_MODEL}, base_url: {OLLAMA_BASE_URL}")
        except Exception as e:
            error_msg = f"Error initializing Langchain LLM: {e}"
            current_errors.append(error_msg)
            print(error_msg, file=sys.stderr)

        # 2. Define Prompt Template
        try:
            self.prompt_template = ChatPromptTemplate.from_messages([
                ("system", (
                    "You are a helpful AI assistant. Answer the user's questions to the best of your ability. "
                    "Use the provided chat history and retrieved context to inform your responses. "
                    "If the context or history is not relevant, rely on your general knowledge.\n\n"
                    "Chat History:\n{chat_history}\n\n"
                    "Retrieved Context from Documents:\n{context}"
                )),
                ("user", "{user_prompt}")
            ])
        except Exception as e:
            error_msg = f"Error creating ChatPromptTemplate: {e}"
            current_errors.append(error_msg)
            print(error_msg, file=sys.stderr)

        # 3. Construct the Chain if LLM and Prompt are available
        if self.llm and self.prompt_template:
            try:
                # RunnablePassthrough.assign allows adding new keys to the dict passed through the chain
                chain_with_memory_and_rag = RunnablePassthrough.assign(
                    chat_history=RunnableLambda(self._get_chat_history_from_mem0),
                    context=RunnableLambda(self._get_context_from_chroma)
                )
                
                self.chain = chain_with_memory_and_rag | self.prompt_template | self.llm | StrOutputParser()
                print("Langchain chain successfully constructed with Mem0 history and ChromaDB RAG.")
            except Exception as e:
                error_msg = f"Error constructing the main Langchain chain: {e}"
                current_errors.append(error_msg)
                print(error_msg, file=sys.stderr)
        elif not current_errors: # If no previous errors, but llm or prompt is missing
             current_errors.append("LLM or PromptTemplate not initialized, main chain cannot be built.")
        
        if current_errors:
            self.initialization_error = "\n".join(current_errors)

    async def invoke_chain(self, user_prompt: str, conversation_id: Optional[str]) -> str:
        """Invokes the main Langchain chain with the given input."""
        if not self.chain:
            raise RuntimeError("Langchain chain is not initialized.")
        if self.initialization_error: # Or raise a more specific error
             raise RuntimeError(f"Langchain pipeline has initialization errors: {self.initialization_error}")

        # The chain expects a dictionary with 'user_prompt' and 'conversation_id'
        # These are used by the Runnables assigned to 'chat_history' and 'context'
        response_content = await self.chain.ainvoke({
            "user_prompt": user_prompt,
            "conversation_id": conversation_id
        })
        return response_content

    def get_status(self) -> tuple[str, str | None]:
        """Returns the status of the Langchain pipeline ('ok', 'error') and an error message if any."""
        if self.initialization_error:
            return "error", self.initialization_error
        if self.chain and self.llm and self.prompt_template:
            return "ok", "Langchain pipeline initialized successfully."
        return "error", "Langchain pipeline components not fully initialized."

# Initialize a global instance
langchain_pipeline_manager = LangchainPipelineManager()
