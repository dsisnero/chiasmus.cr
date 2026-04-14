## I guess we can assume that\... {#i-guess-we-can-assume-that... .wiki}

If the functions return `FALSE`, then there is nothing to deallocate in `s`.

## Rewritten example for \"write in C\" {#rewritten-example-for-write-in-c .wiki}

I reworked the example into a smoother version. Is it correct? It definitely needs extension for multibyte/UTF-8 characters (how do I do that? to be found out!)

``` {.code ext=""}

// ---
// The Sprint* functions will end up in
// int Svfprintf(IOSTREAM *s, const char *fm, va_list args)
// of pl-stream.c (a function which is too long and needs to be broken up)
// It returns the number of chars printed.
// ---

foreign_t
pl_display(term_t t) {
    switch (PL_term_type(t)) {
        case PL_VARIABLE: // variable will be converted to print-name
        case PL_ATOM: // FIXME what if Atom is multibyte, then conversion fails
        case PL_INTEGER:
        case PL_FLOAT: {
            char *s;
            int res = PL_get_chars(t, &s, CVT_ALL); // CVT_ALL: convert anything
            if (res) {
                Sprintf("%s", s);  // from SWI-Stream.h/pl-stream.c
            }
            return res; // "fail" if there was a problem in PL_get_chars()
        }
        case PL_STRING: {
            // FIXME what if String is multibyte, then conversion fails
            // FIXME need to do this differently to get the "right bytes" on the outstream
            char *s; // this will be a pointer that can be invalidated by Prolog, so dump it ASAP
            size_t len;
            int res = PL_get_string_chars(t, &s, &len);
            if (res) {
                Sprintf("\"%s\"", s);  // from SWI-Stream.h/pl-stream.c
            }
            return res; // "fail" if there was a problem in PL_get_string_chars()
        }
        case PL_TERM: {
            term_t new_t = PL_new_term_ref();
            size_t arity;
            atom_t name;
            int res = PL_get_name_arity(t, &name, &arity);
            if (res) {
                Sprintf("%s(", PL_atom_chars(name)); // FIXME fails if functor name is multibyte
            }
            for (size_t n = 1; (n <= arity) && res; n++) {
                term_t arg;
                res = PL_get_arg(n, t, arg); // assign into "arg"
                if ((n > 1) && res) {
                    Sprintf(", ");
                }
                res = pl_display(arg); // Recursive call!
            }
            if (res) {
                Sprintf(")");
            }
            return res; // "fail" if there was any problem
        }
        default:
            PL_fail; // type not catered for
    } // end switch
}
```

## Multibyte and stuff {#multibyte-and-stuff .wiki}

At <https://www.cprogramming.com/tutorial/unicode.html> Jeff Bezanson gives us a few definitions:

> **\"Multibyte character\"** or \"multibyte string\" refers to text in one of the many (possibly language-specific) encodings that exist throughout the world. A multibyte character does not necessarily require more than one byte to store; the term is merely intended to be broad enough to encompass encodings where this is the case. UTF-8 is in fact only one such encoding; the actual encoding of user input is determined by the user\'s current locale setting (selected as an option in a system dialog or stored as an environment variable in UNIX). Strings you get from the user will be in this encoding, and strings you pass to `printf()` are supposed to be as well. Strings within your program can of course be in any encoding you want, but you might have to convert them for proper display.

> **\"Wide character\"** or \"wide character string\" refers to text where each character is the same size (usually a 32-bit integer) and simply represents a Unicode character value (\"code point\"). This format is a known common currency that allows you to get at character values if you want to. The `wprintf()` family is able to work with wide character format strings, and the \"%ls\" format specifier for normal `printf()` will print wide character strings (converting them to the correct locale-specific multibyte encoding on the way out).

Also compares the available encoding options: UTF-8, wide character, multibyte character.

That page also contains code to perform UTF-8 string handling.

## See also {#see-also .wiki}

- <https://en.wikipedia.org/wiki/C_string_handling>
- <https://stackoverflow.com/questions/3996026/what-is-the-default-encoding-for-c-strings>
- <http://illegalargumentexception.blogspot.com/2010/04/i18n-comparing-character-encoding-in-c.html>

## See also this \"hello world\" example {#see-also-this-hello-world-example .wiki}

[Exercise: Compile a shared library written in C for use by SWI-Prolog](https://github.com/dtonhofer/prolog_notes/tree/master/foreign_interface_trial/sayhellolib)
:::
::::
::::::

::: post-login
**[login](/openid/login?openid.return_to=/pldoc/man?section%3Dforeign-term-analysis){.signin}** to add a new annotation post.
:::
:::::::::::::

:::: {#footer}
::: current-user
[login](/openid/login?openid.return_to=/pldoc/man?section%3Dforeign-term-analysis){.signin}
:::

[Powered by SWI-Prolog 10.1.5-7-gb9f48137e](http://www.swi-prolog.org){#powered}
::::
::::::::::::::::
:::::::::::::::::

::: {#tail-end}
 
:::
::::::::::::::::::::::::::::::
