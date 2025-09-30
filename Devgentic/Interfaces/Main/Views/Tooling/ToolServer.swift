import Hummingbird
import ServiceLifecycle
import Logging
import NIOCore
import Foundation

/// A singleton actor to manage the lifecycle of the embedded Hummingbird web server.
actor ToolServer {
    static let shared = ToolServer()

    private var application: Application<RouterResponder<BasicRequestContext>>?
    private var serviceGroup: ServiceGroup?
    private var runningTask: Task<Void, Error>?
    private var assignedPort: Int?

    private let logger = Logger(label: "ToolServer")

    // A continuation to signal when the port has been assigned.
    private var portAssignedContinuation: CheckedContinuation<Int, Never>?

    private init() {} // Enforce singleton via static 'shared' property.

    /// Asynchronously returns the port the server is currently running on.
    /// This will wait until the server has successfully started and the port is known.
    func currentPort() async -> Int {
        if let port = assignedPort {
            return port
        }
        // If the port isn't assigned yet, wait for the continuation.
        return await withCheckedContinuation { continuation in
            self.portAssignedContinuation = continuation
        }
    }

    /// Builds the router and defines all the API endpoints for the server.
    private func buildRouter() -> Router<BasicRequestContext> {
        let router = Router(context: BasicRequestContext.self)
        router.add(middleware: LogRequestsMiddleware(.info))

        // GET /health - A simple endpoint to check if the server is running.
        router.get("health") { _, _ -> HTTPResponse.Status in
            return .ok
        }
        
        // POST /execute_tool - The endpoint for executing registered tools.
        router.post("execute_tool", use: executeToolHandler)

        return router
    }
    
    /// Handles requests to the /execute_tool endpoint.
    private func executeToolHandler(_ request: Request, context: some RequestContext) async throws -> some ResponseEncodable {
        do {
            // 1. Decode the incoming JSON request into our Swift model.
            let toolRequest = try await request.decode(as: ExecuteToolRequest.self, context: context)
            
            // 2. Convert the [String: AnyCodable] arguments to the [String: Any] format.
            let arguments = toolRequest.arguments.mapValues { $0.value }
            
            // 3. Execute the tool using the new UnifiedToolExecutor.
            // This now seamlessly handles both local and MCP tools.
            let result = await UnifiedToolExecutor.shared.execute(name: toolRequest.name, arguments: arguments)
            
            // 4. Return a successful response containing the tool's output.
            return ExecuteToolResponse(result: result)
            
        } catch let decodingError as DecodingError {
            // If JSON decoding fails, return a 400 Bad Request error with details.
            logger.error("Failed to decode request body: \(decodingError)")
            throw HTTPError(.badRequest, message: "Invalid request body: \(decodingError.localizedDescription)")
        } catch {
            // For any other unexpected errors, return a 500 Internal Server Error.
            logger.error("An unexpected error occurred while executing tool: \(error)")
            throw HTTPError(.internalServerError, message: "An internal server error occurred.")
        }
    }
    
    /// An actor-isolated method to safely update the server's port.
    private func setAssignedPort(_ port: Int) {
        self.assignedPort = port
        self.portAssignedContinuation?.resume(returning: port)
        self.logger.info("Server started and listening on port \(port)")
    }

    /// Configures and builds the Hummingbird application instance.
    private func buildApplication() -> Application<RouterResponder<BasicRequestContext>> {
        let router = buildRouter()
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0)), // Port 0 lets the OS assign a free port.
            onServerRunning: { channel in
                // This callback is triggered once the server is running.
                if let port = channel.localAddress?.port {
                    // We must call an async method on the actor to mutate its state.
                    Task {
                        await self.setAssignedPort(port)
                    }
                }
            },
            logger: self.logger
        )
        return app
    }

    /// Starts the web server in a background task.
    func start() throws {
        guard self.runningTask == nil else {
            logger.warning("Server is already running.")
            return
        }

        let app = buildApplication()
        self.application = app

        // We explicitly disable the default signal handling so the macOS app lifecycle
        // has full control over starting and stopping the server.
        let serviceGroup = ServiceGroup(
            services: [app],
            gracefulShutdownSignals: [], // Disable signal handling
            logger: self.logger
        )
        self.serviceGroup = serviceGroup
        logger.info("Starting server...")

        // Run the service group in a new detached Task to avoid blocking the main UI thread.
        self.runningTask = Task.detached {
            try await serviceGroup.run()
            // This line runs after the server has fully shut down.
            await self.didStop()
        }
    }

    /// Resets the server's state after it has stopped.
    private func didStop() {
        logger.info("Server has stopped.")
        self.runningTask = nil
        self.serviceGroup = nil
        self.application = nil
        self.assignedPort = nil
        self.portAssignedContinuation = nil
    }

    /// Triggers a graceful shutdown of the web server.
    func stop() async {
        guard let serviceGroup = self.serviceGroup, self.runningTask != nil else {
            logger.warning("Server is not running or is already stopping.")
            return
        }
        logger.info("Stopping server gracefully...")
        await serviceGroup.triggerGracefulShutdown()

        // Wait for the running task to complete to ensure shutdown is finished.
        do {
            try await self.runningTask?.value
            logger.info("Server shutdown complete.")
        } catch {
            logger.error("Server shutdown encountered an error: \(error)")
        }
    }
}
