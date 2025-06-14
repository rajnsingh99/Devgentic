# import sys
# import os
# import urllib.parse
# from typing import Optional, Dict, Any, List
#
# try:
#     import tiktoken
# except ImportError:
#     tiktoken = None
#
# from .api_models import (
#     ChatRequest, AddDocumentRequest, ChatResponse, AddDocumentResponse,
#     ChatConfigItem, Alert, Suggestion, Action, SummarizeRequest, SummarizeResponse
# )
# from .Utils.conversation_storage_manager import conversation_storage_manager, format_conversation_history_for_prompt
# from .Utils.vectorstore_client import vector_store_manager
# from Utils.langchain_components import langchain_pipeline_manager
# from langchain_ollama.chat_models import ChatOllama
# from langchain_core.prompts import ChatPromptTemplate
# from langchain_core.output_parsers import StrOutputParser
#
#
# class ChatService:
#     """Service layer containing the core business logic for the chat application."""
#
#     def __init__(self):
#         self.is_ready = False
#         self._last_chat_config_store: Dict[str, ChatConfigItem] = {}
#         self.tokenizer = None
#
#         if tiktoken:
#             try:
#                 self.tokenizer = tiktoken.get_encoding("cl100k_base")
#                 print("Tiktoken tokenizer initialized successfully.", file=sys.stdout)
#             except Exception as e:
#                 print(f"Could not initialize tiktoken tokenizer: {e}", file=sys.stderr)
#         else:
#             print("Tiktoken library not found. Context management features will be disabled.", file=sys.stderr)
#
#         lc_status, lc_msg = langchain_pipeline_manager.get_status()
#         self.is_ready = lc_status in ["ok", "degraded"]
#
#         if not self.is_ready:
#             print(f"ChatService initialized, but LangchainPipelineManager reported an error: {lc_msg}. Check logs.",
#                   file=sys.stderr)
#         elif lc_status == "degraded":
#             print(
#                 f"ChatService initialized, but LangchainPipelineManager reported a degraded state: {lc_msg}. Some operations might be affected.",
#                 file=sys.stdout)
#         else:
#             print("ChatService initialized and ready.", file=sys.stdout)
#
#     def _read_file_content_from_uris(self, files: List[Dict]) -> str:
#         """Reads content from a list of file URIs and formats it for the prompt."""
#         if not files:
#             return ""
#
#         all_file_content = ["--- Attached Files ---"]
#         for f in files:
#             uri_string = f.get('uri')
#             if not uri_string:
#                 continue
#             try:
#                 parsed_uri = urllib.parse.urlparse(uri_string)
#                 if parsed_uri.scheme == 'file':
#                     file_path = urllib.parse.unquote(parsed_uri.path)
#                     if sys.platform == "win32" and file_path.startswith('/'):
#                         file_path = file_path[1:]
#                 else:
#                     file_path = uri_string
#                 if os.path.exists(file_path):
#                     with open(file_path, 'r', encoding='utf-8') as file:
#                         content = file.read()
#                     file_info = f"File: {f.get('name', os.path.basename(file_path))}\n\n{content}"
#                     all_file_content.append(file_info)
#                 else:
#                     all_file_content.append(f"File: {f.get('name', 'N/A')} (Error: Not found at path {file_path})")
#             except Exception as e:
#                 all_file_content.append(
#                     f"File: {f.get('name', 'N/A')} (Error: Could not read file at {uri_string}. Reason: {e})")
#
#         all_file_content.append("--- End of Files ---")
#         return "\n\n".join(all_file_content) + "\n\n"
#
#     def _has_chat_config_changed(self, conversation_id: str, new_config: ChatConfigItem) -> bool:
#         """Compares the new chat config with the last known config for the conversation."""
#         last_config = self._last_chat_config_store.get(conversation_id)
#         return last_config != new_config
#
#     async def _get_llm_conversation_summary(self, conversation_id: str, llm_instance: Optional[ChatOllama],
#                                             history_limit: int = 50) -> str:
#         """Generates a concise summary of the conversation history."""
#         if not llm_instance:
#             return ""
#         storage_status, _ = conversation_storage_manager.is_available()
#         if storage_status in ["error", "disabled"]:
#             return "Conversation history is not available."
#         try:
#             history_memories: List[Any] = conversation_storage_manager.get_history(user_id=conversation_id,
#                                                                                    limit=history_limit)
#             if not history_memories:
#                 return "No conversation history found to summarize."
#
#             formatted_history = format_conversation_history_for_prompt(history_memories)
#             summarization_prompt_text = (
#                 "You are an expert summarizer. Provide a concise summary of the following conversation, focusing on key topics, decisions, and unresolved questions. The summary should be dense and capture the essence of the dialogue.\n\n"
#                 f"Conversation History:\n{formatted_history}\n\nConcise Summary:"
#             )
#             prompt_template = ChatPromptTemplate.from_messages([("human", summarization_prompt_text)])
#             summarization_chain = prompt_template | llm_instance | StrOutputParser()
#             summary = await summarization_chain.ainvoke({})
#             return summary.strip()
#         except Exception as e:
#             print(f"Error during LLM conversation summarization for {conversation_id}: {e}", file=sys.stderr)
#             return f"Error creating summary: {e}"
#
#     def _build_suggestion_payload(self) -> Suggestion:
#         """Builds the standard suggestion object for when context is nearly full."""
#         actions = [
#             Action(type="new_chat_with_summary", displayText="Start New Chat with Summary"),
#             Action(type="upgrade_llm", displayText="Upgrade LLM for Larger Context")
#         ]
#         suggested_models = ["llama3:70b", "gpt-4-turbo"]
#         return Suggestion(actions=actions, suggested_models=suggested_models)
#
#     async def process_chat_interaction(self, request_payload: ChatRequest) -> ChatResponse:
#         """Processes a chat interaction with context-aware token management."""
#         conversation_id = request_payload.conversation_id
#         print(f"\n[ChatService] --- START: Processing request for conversation_id: {conversation_id} ---",
#               file=sys.stdout)
#
#         user_prompt = request_payload.message_content.prompt
#         files = [f.model_dump() for f in request_payload.message_content.files]
#         active_chat_config = request_payload.chat_config[0]
#         llm_settings = active_chat_config.llm_settings
#
#         if self._has_chat_config_changed(conversation_id, active_chat_config):
#             print(f"[ChatService] Config changed. Updating LLM to: {llm_settings.model_name}", file=sys.stdout)
#             langchain_pipeline_manager.update_llm_and_rebuild_chain(
#                 new_ollama_url=str(llm_settings.base_url),
#                 new_model_name=llm_settings.model_name
#             )
#         self._last_chat_config_store[conversation_id] = active_chat_config
#
#         print(f"[ChatService] Retrieving history and file content.", file=sys.stdout)
#         file_content_prompt = self._read_file_content_from_uris(files)
#         history_memories = conversation_storage_manager.get_history(user_id=conversation_id, limit=50)
#         history_prompt = format_conversation_history_for_prompt(history_memories)
#
#         final_prompt_to_llm = ""
#         alert_payload: Optional[Alert] = None
#         suggestion_payload: Optional[Suggestion] = None
#
#         context_window = llm_settings.context_window_size
#         if not self.tokenizer or not context_window or context_window <= 0:
#             final_prompt_to_llm = f"{history_prompt}\n\n{file_content_prompt}{user_prompt}"
#             print(f"[ChatService] Warning: Context management disabled. Proceeding with full prompt.", file=sys.stderr)
#         else:
#             full_prompt_text = f"{history_prompt}\n\n{file_content_prompt}{user_prompt}"
#             token_count = len(self.tokenizer.encode(full_prompt_text))
#             context_usage = token_count / context_window
#             print(
#                 f"[ChatService] Token evaluation: Count={token_count}, Window={context_window}, Usage={context_usage:.2%}",
#                 file=sys.stdout)
#
#             if context_usage < 0.8:
#                 final_prompt_to_llm = full_prompt_text
#             elif 0.8 <= context_usage <= 1.0:
#                 final_prompt_to_llm = full_prompt_text
#                 suggestion_payload = self._build_suggestion_payload()
#             else:
#                 final_prompt_to_llm = f"{file_content_prompt}{user_prompt}"
#                 alert_payload = Alert(
#                     level="critical",
#                     title="Context Limit Exceeded",
#                     message="The conversation history is too long. To continue, the oldest messages were not included in this turn. Accuracy may be affected."
#                 )
#                 suggestion_payload = self._build_suggestion_payload()
#
#         print(f"[ChatService] Adding user message to DB: '{user_prompt[:50]}...'", file=sys.stdout)
#         storage_status, _ = conversation_storage_manager.is_available()
#         if storage_status in ["ok", "degraded"]:
#             conversation_storage_manager.add_message(data=user_prompt, user_id=conversation_id, role="user")
#
#         print(f"[ChatService] Invoking Langchain pipeline.", file=sys.stdout)
#         ai_response_content = await langchain_pipeline_manager.invoke_chain(
#             user_prompt=final_prompt_to_llm,
#             conversation_id=conversation_id
#         )
#
#         print(f"[ChatService] Adding AI response to DB: '{ai_response_content[:50]}...'", file=sys.stdout)
#         if ai_response_content and storage_status in ["ok", "degraded"]:
#             conversation_storage_manager.add_message(data=ai_response_content, user_id=conversation_id, role="ai")
#
#         print(f"[ChatService] --- END: Request processed for conversation_id: {conversation_id} ---\n", file=sys.stdout)
#         return ChatResponse(
#             response=ai_response_content,
#             conversation_id=conversation_id,
#             alert=alert_payload,
#             suggestion=suggestion_payload
#         )
#
#     async def summarize_conversation(self, request_payload: SummarizeRequest) -> SummarizeResponse:
#         """Handles the logic for the new summarization endpoint."""
#         conversation_id = request_payload.conversation_id
#         llm_instance = langchain_pipeline_manager.llm
#         if not llm_instance:
#             raise RuntimeError("LLM is not available to perform summarization.")
#         summary_text = await self._get_llm_conversation_summary(conversation_id, llm_instance)
#         return SummarizeResponse(summary=summary_text)
#
#     def add_document_to_vectorstore(self, request_payload: AddDocumentRequest) -> AddDocumentResponse:
#         if not vector_store_manager.vectorstore:
#             raise RuntimeError("Vector store (ChromaDB) is not available.")
#         doc_metadata = {"source": request_payload.source}
#         if request_payload.metadata:
#             doc_metadata.update(request_payload.metadata)
#         success, doc_ids = vector_store_manager.add_documents(texts=[request_payload.text], metadatas=[doc_metadata])
#         if success:
#             doc_id = doc_ids[0] if doc_ids else None
#             return AddDocumentResponse(
#                 message="Document added successfully to ChromaDB.",
#                 document_id=doc_id,
#                 text_preview=request_payload.text[:100] + "...",
#                 metadata=doc_metadata
#             )
#         else:
#             raise RuntimeError("Failed to add document to ChromaDB.")
#
#
# chat_service = ChatService()
