## Mode indicators? {#mode-indicators .wiki}

It\'s a bit unusual to see the C parameter names tagged with a \'-\' mode indicator as if they were Prolog arguments. Is this really a good idea?

## An error in the text. {#an-error-in-the-text. .wiki}

``` {.code ext=""}

int PL_put_pointer(term_t -t, void *ptr)

    Put a Prolog integer in the term reference.
```

Should be \"encode a pointer in the term reference\" (in the term reference is correct, as the value of `term_t` itself is changed)

(This is done via inline functions in pl-inline.h btw., which are underneath a comment that seems to apply to an earlier version as it says \"the heap_base is subtracted\" which does not happen)

The remark

> Provided ptr is in the'`malloc()`-area\', PL_get_pointer() will get the pointer back.

needs to be clarified I guess. There seems to be no restrictions as to the pointer value in the code itself.
:::
::::
::::::

::: post-login
**[login](/openid/login?openid.return_to=/pldoc/man?section%3Dforeign-term-construct){.signin}** to add a new annotation post.
:::
:::::::::::::

:::: {#footer}
::: current-user
[login](/openid/login?openid.return_to=/pldoc/man?section%3Dforeign-term-construct){.signin}
:::

[Powered by SWI-Prolog 10.1.5-7-gb9f48137e](http://www.swi-prolog.org){#powered}
::::
::::::::::::::::
:::::::::::::::::

::: {#tail-end}
 
:::
:::::::::::::::::::::::::::::
