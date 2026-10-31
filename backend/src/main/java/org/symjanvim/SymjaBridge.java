package org.symjanvim;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.NullNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.matheclipse.core.eval.EvalEngine;
import org.matheclipse.core.eval.ExprEvaluator;
import org.matheclipse.core.eval.TeXUtilities;
import org.matheclipse.core.expression.S;
import org.matheclipse.core.interfaces.IExpr;
import org.matheclipse.core.interfaces.ISymbol;
import org.matheclipse.core.parser.ExprParser;
import org.matheclipse.core.parser.ExprParserFactory;
import org.matheclipse.parser.client.SyntaxError;

import java.io.BufferedReader;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.PrintStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Long-lived JSON-lines bridge between Neovim and a stateful Symja evaluator. */
public final class SymjaBridge {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final Pattern DEFINITION_NAME = Pattern.compile(
            "(?m)(?:^|[;\\n])\\s*([\\p{L}$][\\p{L}\\p{N}$]*)\\s*(?:(?:\\([^;\\n]*\\))|(?:\\[[^;\\n]*\\]))?\\s*(?::=|=(?!=))");
    private static final List<String> BUILTIN_SYMBOLS = discoverBuiltinSymbols();

    private ExprEvaluator evaluator;
    private final Set<String> userSymbols = new TreeSet<>();

    private SymjaBridge() {
        resetEvaluator();
    }

    private void resetEvaluator() {
        // Symja's Global context may outlive an EvalEngine instance. Clear symbols
        // learned by this bridge before replacing the engine, or :SymjaReset could
        // leave stale assignments/DownValues behind in a reused context.
        if (evaluator != null) {
            for (String name : userSymbols) {
                // Never clear built-in symbols (e.g. Integrate, Pi, or D).
                if (BUILTIN_SYMBOLS.contains(name)) {
                    continue;
                }
                try {
                    evaluator.eval("ClearAll(" + name + ")");
                } catch (Exception ignored) {
                    // A fresh engine is still created below; ignore cleanup errors.
                }
            }
        }
        evaluator = new ExprEvaluator(false, (short) 100);
        userSymbols.clear();
    }

    /** Parse source without evaluating it or changing the current evaluator state. */
    private ObjectNode checkSyntax(String code, String mode) {
        ObjectNode result = JSON.createObjectNode();
        ArrayNode diagnostics = result.putArray("diagnostics");
        try {
            EvalEngine engine = evaluator.getEvalEngine();
            EvalEngine.setReset(engine);
            ExprParser parser;
            if ("native".equals(mode)) {
                parser = new ExprParser(engine, ExprParserFactory.RELAXED_STYLE_FACTORY, true);
            } else if ("mma".equals(mode)) {
                parser = new ExprParser(engine, ExprParserFactory.MMA_STYLE_FACTORY, false);
            } else {
                throw new IllegalArgumentException(
                        "Unknown syntax mode '" + mode + "' (expected native or mma)");
            }
            parser.parse(code);
            result.put("ok", true);
        } catch (SyntaxError error) {
            ObjectNode diagnostic = diagnostics.addObject();
            // SyntaxError stores a zero-based row and a 1-based column.
            diagnostic.put("line", Math.max(0, error.getRowIndex()));
            diagnostic.put("column", Math.max(0, error.getColumnIndex() - 1));
            diagnostic.put("length", Math.max(1, error.getLength()));
            String message = error.getError();
            diagnostic.put("message", message == null || message.isBlank()
                    ? error.getMessage() : message);
            diagnostic.put("severity", "error");
            result.put("ok", true);
        } catch (RuntimeException error) {
            result.put("ok", false);
            String message = error.getMessage();
            result.put("error", message == null || message.isBlank()
                    ? error.getClass().getSimpleName() : message);
        }
        return result;
    }

    private IExpr parse(String code, String mode) throws SyntaxError {
        EvalEngine engine = evaluator.getEvalEngine();
        EvalEngine.setReset(engine);
        if ("native".equals(mode)) {
            ExprParser parser = new ExprParser(engine, ExprParserFactory.RELAXED_STYLE_FACTORY, true);
            return parser.parse(code);
        }
        if ("mma".equals(mode)) {
            ExprParser parser = new ExprParser(engine, ExprParserFactory.MMA_STYLE_FACTORY, false);
            return parser.parse(code);
        }
        throw new IllegalArgumentException("Unknown syntax mode '" + mode + "' (expected native or mma)");
    }

    private IExpr evaluate(String code, String mode) throws SyntaxError {
        if ("native".equals(mode)) {
            return evaluator.eval(code);
        }
        return evaluator.eval(parse(code, mode));
    }

    private String toLatex(IExpr expression) {
        if (expression == null) {
            return "";
        }
        StringWriter writer = new StringWriter();
        try {
            TeXUtilities tex = new TeXUtilities(evaluator.getEvalEngine(), false);
            if (tex.toTeX(expression, writer)) {
                return writer.toString();
            }
        } catch (RuntimeException ignored) {
            // Preserve the ordinary result if Symja cannot format this expression.
        }
        return expression.toString();
    }

    private void rememberDefinitions(String code) {
        Matcher matcher = DEFINITION_NAME.matcher(code);
        while (matcher.find()) {
            String name = matcher.group(1);
            if (name != null && !name.isBlank()) {
                userSymbols.add(name);
            }
        }
    }

    private List<String> completions(String prefix) {
        String lowerPrefix = prefix == null ? "" : prefix.toLowerCase(java.util.Locale.ROOT);
        Set<String> all = new LinkedHashSet<>(BUILTIN_SYMBOLS);
        all.addAll(userSymbols);
        List<String> matches = new ArrayList<>();
        for (String name : all) {
            if (name.toLowerCase(java.util.Locale.ROOT).startsWith(lowerPrefix)) {
                matches.add(name);
            }
        }
        matches.sort(String.CASE_INSENSITIVE_ORDER);
        return matches;
    }

    private static List<String> discoverBuiltinSymbols() {
        Set<String> names = new TreeSet<>(String.CASE_INSENSITIVE_ORDER);
        for (Field field : S.class.getFields()) {
            if (!Modifier.isStatic(field.getModifiers())) {
                continue;
            }
            if (!ISymbol.class.isAssignableFrom(field.getType())) {
                continue;
            }
            String name = field.getName();
            if (name.matches("[\\p{L}$][\\p{L}\\p{N}$]*")) {
                names.add(name);
            }
        }
        return List.copyOf(names);
    }

    public static void main(String[] args) throws Exception {
        PrintWriter protocolOut = new PrintWriter(
                new OutputStreamWriter(new FileOutputStream(FileDescriptor.out), StandardCharsets.UTF_8), true);
        // Keep JSON-lines protocol stdout clean if a dependency writes diagnostics to System.out.
        System.setOut(new PrintStream(new FileOutputStream(FileDescriptor.err), true, StandardCharsets.UTF_8));
        SymjaBridge bridge = new SymjaBridge();

        try (BufferedReader in = new BufferedReader(
                new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
            String line;
            while ((line = in.readLine()) != null) {
                if (line.isBlank()) {
                    continue;
                }
                ObjectNode response = JSON.createObjectNode();
                try {
                    JsonNode request = JSON.readTree(line);
                    JsonNode id = request.get("id");
                    response.set("id", id == null ? NullNode.getInstance() : id);
                    String method = request.path("method").asText("eval");
                    switch (method) {
                        case "ping" -> response.put("result", "pong");
                        case "reset" -> {
                            bridge.resetEvaluator();
                            response.put("result", "Symja evaluator reset");
                        }
                        case "eval" -> {
                            String code = request.path("code").asText("");
                            String mode = request.path("mode").asText("native");
                            IExpr result = bridge.evaluate(code, mode);
                            bridge.rememberDefinitions(code);
                            response.put("result", result == null ? "" : result.toString());
                            if (request.path("renderLatex").asBoolean(false)) {
                                response.put("latex", bridge.toLatex(result));
                            }
                        }
                        case "latex" -> {
                            String code = request.path("code").asText("");
                            String mode = request.path("mode").asText("native");
                            // Format the parsed AST without evaluating it. This preserves
                            // operators such as Integrate, Sum, D, and Limit for typesetting.
                            IExpr expression = bridge.parse(code, mode);
                            response.put("result", expression == null ? "" : expression.toString());
                            response.put("latex", bridge.toLatex(expression));
                        }
                        case "check" -> {
                            String code = request.path("code").asText("");
                            String mode = request.path("mode").asText("native");
                            ObjectNode checked = bridge.checkSyntax(code, mode);
                            if (!checked.path("ok").asBoolean(false)) {
                                throw new IllegalArgumentException(checked.path("error").asText("Syntax check failed"));
                            }
                            response.set("diagnostics", checked.path("diagnostics"));
                        }
                        case "complete" -> {
                            String prefix = request.path("code").asText("");
                            ArrayNode symbols = response.putArray("symbols");
                            for (String symbol : bridge.completions(prefix)) {
                                symbols.add(symbol);
                            }
                            response.put("result", "");
                        }
                        default -> throw new IllegalArgumentException("Unknown method: " + method);
                    }
                    response.put("ok", true);
                } catch (Exception error) {
                    response.put("ok", false);
                    String message = error.getMessage();
                    response.put("error", message == null || message.isBlank()
                            ? error.getClass().getSimpleName() : message);
                }
                protocolOut.println(JSON.writeValueAsString(response));
                protocolOut.flush();
            }
        }
    }
}
