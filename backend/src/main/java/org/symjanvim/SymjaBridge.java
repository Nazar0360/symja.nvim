package org.symjanvim;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.NullNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.matheclipse.core.eval.EvalEngine;
import org.matheclipse.core.eval.ExprEvaluator;
import org.matheclipse.core.eval.TeXUtilities;
import org.matheclipse.core.expression.Context;
import org.matheclipse.core.expression.ContextPath;
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
    private static final Set<String> BUILTIN_SYMBOL_NAMES = discoverBuiltinSymbolNames();
    // Symja 3.1.1 stores System symbols under lower-case keys when its global
    // PARSER_USE_LOWERCASE_SYMBOLS setting is enabled. Re-key the same symbols
    // with their Java field names for exact Mathematica symbol resolution.
    private static final Context MMA_SYSTEM_CONTEXT = discoverMmaSystemContext();

    private ExprEvaluator evaluator;
    private ContextPath nativeContextPath;
    private ContextPath mmaContextPath;
    private final Set<String> userSymbols = new TreeSet<>();

    private SymjaBridge() {
        resetEvaluator();
    }

    private void resetEvaluator() {
        // Symja's Global context may outlive an EvalEngine instance. Clear symbols
        // learned by this bridge before replacing the engine, or :SymjaReset could
        // leave stale assignments/DownValues behind in a reused context.
        if (evaluator != null) {
            EvalEngine engine = evaluator.getEvalEngine();
            // Clear through the exact-case System context so a user symbol such as
            // `square` cannot resolve to Symja's lower-case-keyed built-in `Square`.
            engine.setContextPath(createMmaContextPath(engine.getContextPath()));
            engine.setRelaxedSyntax(false);
            EvalEngine.setReset(engine);
            for (String name : userSymbols) {
                try {
                    ExprParser clearParser = new ExprParser(
                            engine, ExprParserFactory.MMA_STYLE_FACTORY, false);
                    evaluator.eval(clearParser.parse("ClearAll[" + name + "]"));
                } catch (Exception ignored) {
                    // A fresh engine is still created below; ignore cleanup errors.
                }
            }
        }
        evaluator = new ExprEvaluator(false, (short) 100);
        nativeContextPath = evaluator.getEvalEngine().getContextPath();
        mmaContextPath = createMmaContextPath(nativeContextPath);
        userSymbols.clear();
    }

    /** Parse source without evaluating it or changing the current evaluator state. */
    private ObjectNode checkSyntax(String code, String mode) {
        ObjectNode result = JSON.createObjectNode();
        ArrayNode diagnostics = result.putArray("diagnostics");
        EvalEngine engine = evaluator.getEvalEngine();
        boolean previousRelaxedSyntax = engine.isRelaxedSyntax();
        ContextPath previousContextPath = engine.getContextPath();
        try {
            prepareEngine(mode);
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
        } finally {
            engine.setContextPath(previousContextPath);
            engine.setRelaxedSyntax(previousRelaxedSyntax);
        }
        return result;
    }

    private static boolean relaxedSyntaxForMode(String mode) {
        if ("native".equals(mode)) {
            return true;
        }
        if ("mma".equals(mode)) {
            return false;
        }
        throw new IllegalArgumentException("Unknown syntax mode '" + mode + "' (expected native or mma)");
    }

    /** Select both symbol lookup and context keys for the requested syntax. */
    private EvalEngine prepareEngine(String mode) {
        EvalEngine engine = evaluator.getEvalEngine();
        boolean relaxedSyntax = relaxedSyntaxForMode(mode);
        engine.setContextPath(relaxedSyntax ? nativeContextPath : mmaContextPath);
        engine.setRelaxedSyntax(relaxedSyntax);
        EvalEngine.setReset(engine);
        return engine;
    }

    private IExpr parse(String code, String mode) throws SyntaxError {
        EvalEngine engine = prepareEngine(mode);
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
        prepareEngine(mode);
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

    private void rememberDefinitions(String code, String mode) {
        Matcher matcher = DEFINITION_NAME.matcher(code);
        while (matcher.find()) {
            String name = matcher.group(1);
            if (name == null || name.isBlank() || isBuiltinSymbolName(name, mode)) {
                continue;
            }
            // Relaxed Symja normalizes multi-character identifiers to lowercase.
            if ("native".equals(mode) && name.length() > 1) {
                name = name.toLowerCase(java.util.Locale.ROOT);
            }
            userSymbols.add(name);
        }
    }

    private static boolean isBuiltinSymbolName(String name, String mode) {
        if ("native".equals(mode) && name.length() > 1) {
            // BUILTIN_SYMBOLS uses a case-insensitive comparator, matching native lookup.
            return BUILTIN_SYMBOLS.contains(name);
        }
        return BUILTIN_SYMBOL_NAMES.contains(name);
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

    private static Set<String> discoverBuiltinSymbolNames() {
        Set<String> names = new TreeSet<>();
        for (Field field : S.class.getFields()) {
            if (!Modifier.isStatic(field.getModifiers())
                    || !ISymbol.class.isAssignableFrom(field.getType())) {
                continue;
            }
            try {
                ISymbol symbol = (ISymbol) field.get(null);
                if (symbol != null && symbol.getContext().isSystem()) {
                    names.add(field.getName());
                }
            } catch (IllegalAccessException error) {
                throw new ExceptionInInitializerError(error);
            }
        }
        return names;
    }

    private static Context discoverMmaSystemContext() {
        Context context = new Context(Context.SYSTEM_CONTEXT_NAME);
        for (Field field : S.class.getFields()) {
            if (!Modifier.isStatic(field.getModifiers())
                    || !ISymbol.class.isAssignableFrom(field.getType())) {
                continue;
            }
            String name = field.getName();
            if (!name.matches("[\\p{L}$][\\p{L}\\p{N}$]*")) {
                continue;
            }
            try {
                ISymbol symbol = (ISymbol) field.get(null);
                if (symbol != null && symbol.getContext().isSystem()) {
                    context.put(name, symbol);
                }
            } catch (IllegalAccessException error) {
                throw new ExceptionInInitializerError(error);
            }
        }
        return context;
    }

    private static ContextPath createMmaContextPath(ContextPath source) {
        ContextPath path = source.copy();
        if (!path.setContext(Context.SYSTEM_CONTEXT_NAME, MMA_SYSTEM_CONTEXT)) {
            throw new IllegalStateException("Could not install the exact-case Symja System context");
        }
        return path;
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
                            bridge.rememberDefinitions(code, mode);
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
