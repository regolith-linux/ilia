using GLib;
using Math;

namespace Ilia {
    public class ExpressionParser : Object {
        
        public static List<string> tokenize(string expr) {
            List<string> tokens = new List<string>();
            string xpr = expr.replace(" ", ""); // Remove spaces
            expr = xpr;
            int i = 0;
            
            while (i < expr.length) {
                char c = expr[i];

                // Match numbers (integers or decimals)
                if ((c >= '0' && c <= '9') || c == '.' ) {
                    int start = i;
                    while (i < expr.length && ((expr[i] >= '0' && expr[i] <= '9') || expr[i] == '.')) {
                        i++;
                    }
                    tokens.append(expr.substring(start, i - start));
                    continue;
                }

                // Hack to make pi work, instead of handling unicode characters properly
                if (c == "π"[0]) {
                    tokens.append("π");
                    i++;
                    continue;
                }

                // Match function calls (sin, cos, tan, log, ln, sqrt, exp)
                if (c >= 'a' && c <= 'z') {
                    int start = i;
                    while (i < expr.length && expr[i] >= 'a' && expr[i] <= 'z') {
                        i++;
                    }

                    // Handle parenthesis
                    if (i < expr.length && expr[i] == '(') {
                        int func_start = start;
                        int paren_count = 0;

                        while (i < expr.length) {
                            if (expr[i] == '(') paren_count++;
                            if (expr[i] == ')') paren_count--;

                            if (paren_count == 0) break;
                            i++;
                        }

                        tokens.append(expr.substring(func_start, i - func_start));
                    } else {
                        tokens.append(expr.substring(start, i - start));
                    }
                    continue;
                }

                // Match operators & parentheses
                if ("+-*/^()".contains(c.to_string())) {
                    tokens.append(c.to_string());
                    i++;
                    continue;
                }

                i++;
            }

            return tokens;
        }

        public static double parse(string expr) {
            string xpr = expr.replace(" ", "");
            expr = xpr;

            List<string> tokens = tokenize(expr);
            double result = 0;
            double currentValue = 0;
            char op = '+';

            foreach (string token in tokens) {
                if (token == "" || token == null) continue;

                if ("+-*/^".contains(token)) {
                    op = token[0]; // Store operator for next number
                    continue;
                }

                if (token.has_prefix("sin")) {
                    double angle = parse(token.substring(4));
                    currentValue = Math.sin(angle);
                } else if (token.has_prefix("cos")) {
                    double angle = parse(token.substring(4));
                    currentValue = Math.cos(angle);
                } else if (token.has_prefix("tan")) {
                    double angle = parse(token.substring(4));
                    currentValue = Math.tan(angle);
                } else if (token.has_prefix("log")) {
                    double num = parse(token.substring(4));
                    currentValue = Math.log10(num);
                } else if (token.has_prefix("ln")) {
                    double num = parse(token.substring(3));
                    currentValue = Math.log(num);
                } else if (token.has_prefix("exp")) {
                    double num = parse(token.substring(4));
                    currentValue = Math.exp(num);
                } else if (token.has_prefix("sqrt")) {
                    double num = parse(token.substring(5));
                    currentValue = Math.sqrt(num);
                } else if (token == "π") {
                    currentValue = Math.PI;
                } else {
                    if (!double.try_parse(token, out currentValue)) {
                        continue;
                    }
                }

                // Apply operator to result
                switch (op) {
                    case '+': result += currentValue; break;
                    case '-': result -= currentValue; break;
                    case '*': result *= currentValue; break;
                    case '/': if (currentValue != 0) result /= currentValue; break;
                    case '^': result = Math.pow(result, currentValue); break;
                }
            }

            return result;
        }
    }
}

