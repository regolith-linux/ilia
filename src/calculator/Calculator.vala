namespace Ilia.Calculator {
    // The program that works out one value, see ilia-calculator.cc
    private const string HELPER_NAME = "ilia-calculator";
    // Digits a value is rounded to
    public const int SIGNIFICANT_DIGITS = 15;
    // Whole numbers with up to this many digits are shown in full
    public const int WHOLE_NUMBER_DIGITS = 40;
    // Values that are not whole numbers are shown in scientific notation below 10^MIN_PLAIN_EXPONENT
    // and from 10^MAX_PLAIN_EXPONENT on
    public const int MIN_PLAIN_EXPONENT = -6;
    public const int MAX_PLAIN_EXPONENT = 40;
    // Brackets, function arguments and exponents nest at most this deep, which keeps the
    // recursive checks below far from the end of the stack, even for pasted text
    public const int MAX_NESTING = 100;

    /**
     * The path of the helper program: the one next to this program when it runs from a build
     * directory, else the installed one
     */
    public string helper_path() {
        try {
            string own_directory = Path.get_dirname(FileUtils.read_link("/proc/self/exe"));
            string next_to_this = Path.build_filename(own_directory, HELPER_NAME);
            if (FileUtils.test(next_to_this, FileTest.IS_EXECUTABLE))
                return next_to_this;
        } catch (FileError e) {
            // Use the installed helper
        }
        return Path.build_filename(Constants.PKGLIBEXECDIR, HELPER_NAME);
    }

    /**
     * The expression to evaluate for the text, or null when the text cannot have a value.
     *
     * The text must be one complete expression of numbers (with an optional e exponent),
     * the operators + - * / ^, a factorial ! after an operand, brackets, the functions sqrt,
     * sin, cos, tan, ln, exp and abs, and the constants pi and e. A minus sign in front of
     * an operand applies to the whole power. Either a full stop or a comma is a decimal
     * mark; the expression always uses a full stop. Brackets and powers nest at most
     * MAX_NESTING deep.
     */
    public string ? to_expression(string text) {
        if (!new ExpressionReader(text).read())
            return null;
        return text.replace(",", ".");
    }

    /**
     * The text shown for a value printed by the helper
     *
     * The value has an optional minus sign, digits with an optional full stop, and an
     * optional exponent after E. It is rounded to fifteen significant digits, half away
     * from zero, unless it is a whole number of up to forty digits. Small and large values
     * use scientific notation, with the exponent after an e.
     */
    public string format_value(string value, bool whole_number, string decimal_mark) {
        bool negative = value.has_prefix("-");
        string unsigned = negative ? value.substring(1) : value;

        long exponent = 0;
        int exponent_start = unsigned.index_of_char('E');
        if (exponent_start >= 0) {
            exponent = long.parse(unsigned.substring(exponent_start + 1));
            unsigned = unsigned.substring(0, exponent_start);
        }
        int point = unsigned.index_of_char('.');
        string digits = point >= 0 ? unsigned.substring(0, point) + unsigned.substring(point + 1) : unsigned;
        // The power of ten of the first digit
        long magnitude = (point >= 0 ? point : unsigned.length) + exponent - 1;

        int first = 0;
        while (first < digits.length && digits[first] == '0')
            first++;
        if (first == digits.length)
            return "0";
        digits = digits.substring(first);
        magnitude -= first;

        string sign = negative ? "-" : "";
        if (whole_number && magnitude < WHOLE_NUMBER_DIGITS)
            return sign + digits + string.nfill((int) (magnitude + 1 - digits.length), '0');

        // Round to the significant digits: up when the first dropped digit is five or more
        if (digits.length > SIGNIFICANT_DIGITS) {
            bool round_up = digits[SIGNIFICANT_DIGITS] >= '5';
            var rounded = new StringBuilder(digits.substring(0, SIGNIFICANT_DIGITS));
            for (int i = SIGNIFICANT_DIGITS - 1; round_up && i >= 0; i--) {
                round_up = rounded.str[i] == '9';
                rounded.overwrite(i, round_up ? "0" : ((char) (rounded.str[i] + 1)).to_string());
            }
            if (round_up) { // 99...9 became 100...0
                rounded.prepend("1");
                magnitude++;
            }
            digits = rounded.str;
        }
        int last = digits.length;
        while (last > 1 && digits[last - 1] == '0')
            last--;
        digits = digits.substring(0, last);

        if (whole_number || magnitude < MIN_PLAIN_EXPONENT || magnitude >= MAX_PLAIN_EXPONENT) {
            string fraction = digits.length > 1 ? decimal_mark + digits.substring(1) : "";
            return "%s%c%se%ld".printf(sign, digits[0], fraction, magnitude);
        }
        if (magnitude < 0)
            return sign + "0" + decimal_mark + string.nfill((int) (-magnitude - 1), '0') + digits;
        if (digits.length <= magnitude + 1)
            return sign + digits + string.nfill((int) (magnitude + 1 - digits.length), '0');
        return sign + digits.substring(0, (long) magnitude + 1) + decimal_mark + digits.substring((long) magnitude + 1);
    }

    /* The text shown for the output of the helper, or null when it found no value */
    public string ? read_helper_output(string ? output, string decimal_mark) {
        if (output == null || !output.has_suffix("\n"))
            return null;
        string[] parts = output.strip().split(" ");
        if (parts.length != 2 || parts[1] == "" || (parts[0] != "integer" && parts[0] != "decimal"))
            return null;
        return format_value(parts[1], parts[0] == "integer", decimal_mark);
    }

    /* Checks that a text is one complete expression, see to_expression() */
    private class ExpressionReader {
        private const string[] FUNCTIONS = { "sqrt", "sin", "cos", "tan", "ln", "exp", "abs" };
        private const string[] CONSTANTS = { "pi", "e" };

        private string text;
        private int position = 0;
        private int nesting = 0;

        public ExpressionReader (string text) {
            this.text = text;
        }

        public bool read() {
            return expression() && skip_spaces() == text.length;
        }

        // A sum: terms between + and -
        private bool expression() {
            if (!term())
                return false;
            while (next_is('+') || next_is('-'))
                if (!term())
                    return false;
            return true;
        }

        // A product: signed powers between * and /
        private bool term() {
            if (!signed_power())
                return false;
            while (next_is('*') || next_is('/'))
                if (!signed_power())
                    return false;
            return true;
        }

        // A power with any number of minus signs in front, which apply to the whole power.
        // Every nested bracket, function argument and exponent passes through here.
        private bool signed_power() {
            if (nesting == MAX_NESTING)
                return false;
            nesting++;
            while (next_is('-')) {
            }
            bool complete = power();
            nesting--;
            return complete;
        }

        // An operand with any factorials, optionally raised to a signed power: powers group to the right
        private bool power() {
            if (!operand())
                return false;
            while (next_is('!')) {
            }
            return !next_is('^') || signed_power();
        }

        private bool operand() {
            if (next_is('('))
                return expression() && next_is(')');
            skip_spaces();
            if (number())
                return true;
            string name = word();
            if (name in CONSTANTS)
                return true;
            return name in FUNCTIONS && next_is('(') && expression() && next_is(')');
        }

        // Digits with an optional decimal mark, and an optional exponent: e, a sign, digits
        private bool number() {
            int start = position;
            int count = skip_digits();
            if (char_at(position) == '.' || char_at(position) == ',') {
                position++;
                count += skip_digits();
            }
            if (count == 0) {
                position = start;
                return false;
            }
            if (char_at(position) == 'e') {
                int exponent = position++;
                if (char_at(position) == '+' || char_at(position) == '-')
                    position++;
                if (skip_digits() == 0)
                    position = exponent; // Not an exponent: the constant e, which may not follow a number
            }
            return true;
        }

        private string word() {
            int start = position;
            while (char_at(position).isalpha())
                position++;
            return text.substring(start, position - start);
        }

        private bool next_is(char c) {
            if (char_at(skip_spaces()) != c)
                return false;
            position++;
            return true;
        }

        private int skip_digits() {
            int start = position;
            while (char_at(position).isdigit())
                position++;
            return position - start;
        }

        private int skip_spaces() {
            while (char_at(position) == ' ' || char_at(position) == '\t')
                position++;
            return position;
        }

        private char char_at(int index) {
            return index < text.length ? text[index] : '\0';
        }
    }
}
