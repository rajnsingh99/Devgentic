# filename: Utils/agent_tools.py
from langchain_core.tools import tool
from typing import List

# Import our existing utilities to build tools on top of them
from .file_processor import read_files_from_uris
from .vectorstore_client import vector_store_manager, format_chroma_context_for_prompt


@tool
def read_file_content(file_uri: str) -> str:
    """
    Reads the full content of a single file specified by its URI.
    Use this tool to get the contents of a file you need to analyze or summarize.
    The file_uri should be the exact URI provided in the user's request.
    """
    # The read_files_from_uris function expects a list of dictionaries.
    # We wrap our single URI in that structure to reuse the logic.
    file_object = [{"uri": file_uri, "name": file_uri.split('/')[-1]}]
    file_content = read_files_from_uris(file_object)

    if "Error:" in file_content:
        return f"Error reading file: {file_content}"

    return file_content


@tool
def search_knowledge_base(query: str) -> str:
    """
    Searches the RAG (Retrieval-Augmented Generation) knowledge base for
    information on a specific topic. Use this to find historical data,
    documentation, or other stored information.
    """
    print(f"[Agent Tool] Searching knowledge base for: '{query}'")
    docs = vector_store_manager.retrieve_documents(query)
    if not docs:
        return "No relevant information found in the knowledge base for that query."

    # Reuse the existing formatter to return a clean context string
    return format_chroma_context_for_prompt(docs)


# A list of all available tools that the agent orchestrator can use.
available_tools: List = [
    read_file_content,
    search_knowledge_base,
]
