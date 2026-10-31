package org.symjanvim;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.NullNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;

/** Minimal LSP server providing Symja function-reference hover documentation. */
public final class SymjaLspServer {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final int MAX_MESSAGE_BYTES = 16 * 1024 * 1024;

    private final InputStream input;
    private final OutputStream output;
    private final Path pluginRoot;
    private final Path configuredDocsDir;
    private final String rawBaseUrl;
    private final String symjaVersion;
    private final Map<String, String> documents = new HashMap<>();
    private final Map<String, String> documentationCache = new HashMap<>();
    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .followRedirects(HttpClient.Redirect.NORMAL)
            .build();

    private boolean running = true;

    private SymjaLspServer(Path pluginRoot, String docsDir, String rawBaseUrl, String symjaVersion, OutputStream protocolOutput) {
        this.input = new BufferedInputStream(System.in);
        // Keep the original process stdout for LSP frames. System.out is redirected
        // to stderr in main() so library/logging output cannot corrupt the protocol.
        this.output = new BufferedOutputStream(protocolOutput);
        this.pluginRoot = pluginRoot.toAbsolutePath().normalize();
        this.configuredDocsDir = docsDir == null || docsDir.isBlank()
                ? null : Path.of(docsDir).toAbsolutePath().normalize();
        this.symjaVersion = symjaVersion == null || symjaVersion.isBlank() ? "3.1.1" : symjaVersion;
        this.rawBaseUrl = rawBaseUrl == null || rawBaseUrl.isBlank()
                ? "https://raw.githubusercontent.com/axkr/symja_android_library/v" + this.symjaVersion
                    + "/symja_android_library/doc/functions/"
                : (rawBaseUrl.endsWith("/") ? rawBaseUrl : rawBaseUrl + "/");
    }

    public static void main(String[] args) throws Exception {
        // Capture the real stdout before redirecting System.out. LSP frames must
        // go to the process stdout; diagnostics and accidental println() calls
        // must go to stderr so they cannot corrupt Content-Length framing.
        OutputStream protocolOutput = new java.io.FileOutputStream(java.io.FileDescriptor.out);
        System.setOut(new java.io.PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.err), true,
                StandardCharsets.UTF_8));
        Path root = Path.of(args.length > 0 && !args[0].isBlank() ? args[0] : ".");
        String docsDir = args.length > 1 ? args[1] : "";
        String rawBase = args.length > 2 ? args[2] : "";
        String symjaVersion = args.length > 3 ? args[3] : "3.1.1";
        new SymjaLspServer(root, docsDir, rawBase, symjaVersion, protocolOutput).run();
    }

    private void run() throws IOException {
        while (running) {
            byte[] body = readMessage();
            if (body == null) {
                break;
            }
            JsonNode message;
            try {
                message = JSON.readTree(body);
            } catch (Exception error) {
                continue;
            }
            if (message == null || !message.isObject()) {
                continue;
            }
            handle(message);
        }
    }

    private void handle(JsonNode message) throws IOException {
        JsonNode id = message.get("id");
        boolean hasId = id != null && !id.isNull();
        String method = message.path("method").asText("");
        JsonNode params = message.path("params");

        switch (method) {
            case "initialize" -> {
                ObjectNode result = JSON.createObjectNode();
                ObjectNode capabilities = result.putObject("capabilities");
                ObjectNode textDocumentSync = capabilities.putObject("textDocumentSync");
                textDocumentSync.put("openClose", true);
                textDocumentSync.put("change", 1); // Full document sync.
                capabilities.put("hoverProvider", true);
                result.putObject("serverInfo")
                        .put("name", "symja-nvim")
                        .put("version", "1.0.0");
                sendResult(id, result);
            }
            case "initialized", "$/cancelRequest", "$/setTrace", "$/progress" -> {
                // Notifications that do not require a server response.
            }
            case "textDocument/didOpen" -> {
                JsonNode document = params.path("textDocument");
                String uri = document.path("uri").asText("");
                if (!uri.isEmpty()) {
                    documents.put(uri, document.path("text").asText(""));
                }
            }
            case "textDocument/didChange" -> {
                JsonNode document = params.path("textDocument");
                String uri = document.path("uri").asText("");
                JsonNode changes = params.path("contentChanges");
                if (!uri.isEmpty() && changes.isArray() && changes.size() > 0) {
                    // The server advertises full sync, so the final change contains the full buffer.
                    documents.put(uri, changes.get(changes.size() - 1).path("text").asText(""));
                }
            }
            case "textDocument/didClose" -> {
                String uri = params.path("textDocument").path("uri").asText("");
                documents.remove(uri);
            }
            case "textDocument/hover" -> {
                JsonNode result = hover(params);
                sendResult(id, result == null ? NullNode.getInstance() : result);
            }
            case "shutdown" -> {
                sendResult(id, NullNode.getInstance());
            }
            case "exit" -> running = false;
            default -> {
                if (hasId) {
                    sendError(id, -32601, "Method not found: " + method);
                }
            }
        }
    }

    private JsonNode hover(JsonNode params) {
        String uri = params.path("textDocument").path("uri").asText("");
        String text = documents.get(uri);
        if (text == null) {
            return null;
        }

        JsonNode position = params.path("position");
        int lineNumber = position.path("line").asInt(-1);
        int character = position.path("character").asInt(-1);
        String symbol = symbolAt(text, lineNumber, character);
        if (symbol == null) {
            return null;
        }

        String markdown = loadDocumentation(symbol);
        if (markdown == null || markdown.isBlank()) {
            return null;
        }

        ObjectNode result = JSON.createObjectNode();
        result.putObject("contents")
                .put("kind", "markdown")
                .put("value", markdown);
        return result;
    }

    private static String symbolAt(String text, int lineNumber, int character) {
        if (lineNumber < 0 || character < 0) {
            return null;
        }
        String[] lines = text.split("\\R", -1);
        if (lineNumber >= lines.length) {
            return null;
        }
        String line = lines[lineNumber];
        int index = Math.min(character, line.length());
        int pivot;
        if (index < line.length() && isSymbolCharacter(line.charAt(index))) {
            pivot = index;
        } else if (index > 0 && isSymbolCharacter(line.charAt(index - 1))) {
            pivot = index - 1;
        } else {
            return null;
        }

        int start = pivot;
        int end = pivot + 1;
        while (start > 0 && isSymbolCharacter(line.charAt(start - 1))) start--;
        while (end < line.length() && isSymbolCharacter(line.charAt(end))) end++;

        String token = line.substring(start, end);
        int context = token.lastIndexOf('`');
        if (context >= 0) token = token.substring(context + 1);
        if (!token.matches("[A-Za-z_$][A-Za-z0-9_$]*")) return null;
        return token;
    }

    private static boolean isSymbolCharacter(char value) {
        return Character.isLetterOrDigit(value) || value == '_' || value == '$' || value == '`';
    }

    private String loadDocumentation(String symbol) {
        if (documentationCache.containsKey(symbol)) {
            return documentationCache.get(symbol);
        }

        String markdown = readLocalDocumentation(symbol);
        if (markdown == null) {
            markdown = fetchDocumentation(symbol);
        }
        if (markdown != null) {
            documentationCache.put(symbol, markdown);
        }
        return markdown;
    }

    private String readLocalDocumentation(String symbol) {
        // Mirror lua/symja/init.lua's local_documentation_path() search order:
        // configured location first, then an optional adjacent bundle for this Symja version,
        // then source/docs copies inside or beside the plugin. Only after every
        // local candidate is exhausted may loadDocumentation() use the network.
        Set<Path> directories = new LinkedHashSet<>();
        if (configuredDocsDir != null) {
            addDocumentationDirectory(directories, configuredDocsDir);
            addDocumentationDirectory(directories, configuredDocsDir.resolve("functions"));
            addDocumentationDirectory(directories, configuredDocsDir.resolve("doc/functions"));
            addDocumentationDirectory(directories,
                    configuredDocsDir.resolve("symja_android_library/doc/functions"));
        }

        Path parent = pluginRoot.getParent();
        if (parent != null) {
            Path bundle = parent.resolve("symja-" + symjaVersion);
            addDocumentationDirectory(directories,
                    bundle.resolve("symja_android_library/doc/functions"));
            addDocumentationDirectory(directories, bundle.resolve("doc/functions"));
            addDocumentationDirectory(directories,
                    parent.resolve("symja_android_library/doc/functions"));
        }
        addDocumentationDirectory(directories,
                pluginRoot.resolve("symja_android_library/doc/functions"));
        addDocumentationDirectory(directories, pluginRoot.resolve("doc/functions"));

        for (Path directory : directories) {
            String found = readFile(directory.resolve(symbol + ".md"));
            if (found != null) return found;
        }
        return null;
    }

    private static void addDocumentationDirectory(Set<Path> directories, Path directory) {
        directories.add(directory.toAbsolutePath().normalize());
    }

    private static String readFile(Path path) {
        try {
            if (Files.isRegularFile(path)) {
                return Files.readString(path, StandardCharsets.UTF_8);
            }
        } catch (IOException ignored) {
            // Fall back to the version-pinned upstream copy.
        }
        return null;
    }

    private String fetchDocumentation(String symbol) {
        String encoded = URLEncoder.encode(symbol, StandardCharsets.UTF_8);
        URI uri = URI.create(rawBaseUrl + encoded + ".md");

        // Match the completion/`:SymjaDoc` loader first. In some Linux setups
        // curl is configured with proxy and CA settings that Java's HttpClient
        // does not inherit, so using the same executable keeps hover consistent
        // with completion documentation.
        String fromCurl = fetchWithCurl(uri);
        if (fromCurl != null && !fromCurl.isBlank()) {
            return fromCurl;
        }

        try {
            HttpRequest request = HttpRequest.newBuilder(uri)
                    .timeout(Duration.ofSeconds(8))
                    .header("Accept", "text/plain, text/markdown, */*")
                    .GET()
                    .build();
            HttpResponse<String> response = http.send(request,
                    HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            if (response.statusCode() >= 200 && response.statusCode() < 300) {
                return response.body();
            }
        } catch (Exception ignored) {
            // Hover should simply be unavailable if the reference page cannot be fetched.
        }
        return null;
    }

    private static String fetchWithCurl(URI uri) {
        Process process = null;
        try {
            process = new ProcessBuilder("curl", "--fail", "--silent", "--show-error", "--location",
                    "--max-time", "10", uri.toString())
                    .redirectErrorStream(true)
                    .start();
            byte[] output = process.getInputStream().readAllBytes();
            if (!process.waitFor(12, TimeUnit.SECONDS)) {
                process.destroyForcibly();
                return null;
            }
            if (process.exitValue() == 0) {
                return new String(output, StandardCharsets.UTF_8);
            }
        } catch (Exception ignored) {
            if (process != null) process.destroyForcibly();
            // Fall through to Java's HTTP client if curl is unavailable.
        }
        return null;
    }

    private byte[] readMessage() throws IOException {
        int contentLength = -1;
        while (true) {
            String header = readHeaderLine(input);
            if (header == null) return null;
            if (header.isEmpty()) break;
            int colon = header.indexOf(':');
            if (colon > 0 && header.substring(0, colon).trim().equalsIgnoreCase("Content-Length")) {
                try {
                    contentLength = Integer.parseInt(header.substring(colon + 1).trim());
                } catch (NumberFormatException error) {
                    throw new IOException("Invalid LSP Content-Length header", error);
                }
            }
        }
        if (contentLength < 0 || contentLength > MAX_MESSAGE_BYTES) {
            throw new IOException("Missing or invalid LSP Content-Length: " + contentLength);
        }
        byte[] body = input.readNBytes(contentLength);
        if (body.length != contentLength) {
            throw new EOFException("Unexpected end of input in LSP message body");
        }
        return body;
    }

    private static String readHeaderLine(InputStream input) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        int value;
        while ((value = input.read()) != -1) {
            if (value == '\n') break;
            if (value != '\r') bytes.write(value);
        }
        if (value == -1 && bytes.size() == 0) return null;
        return bytes.toString(StandardCharsets.US_ASCII);
    }

    private void sendResult(JsonNode id, JsonNode result) throws IOException {
        ObjectNode response = JSON.createObjectNode();
        response.put("jsonrpc", "2.0");
        response.set("id", id == null ? NullNode.getInstance() : id.deepCopy());
        response.set("result", result);
        send(response);
    }

    private void sendError(JsonNode id, int code, String message) throws IOException {
        ObjectNode response = JSON.createObjectNode();
        response.put("jsonrpc", "2.0");
        response.set("id", id == null ? NullNode.getInstance() : id.deepCopy());
        response.putObject("error").put("code", code).put("message", message);
        send(response);
    }

    private void send(ObjectNode message) throws IOException {
        byte[] body = JSON.writeValueAsBytes(message);
        byte[] header = ("Content-Length: " + body.length + "\r\n\r\n").getBytes(StandardCharsets.US_ASCII);
        output.write(header);
        output.write(body);
        output.flush();
    }
}
