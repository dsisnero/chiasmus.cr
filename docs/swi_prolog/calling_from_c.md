# SWI-Prolog C Interface Documentation

## Table of Contents

- [12. Foreign Language Interface](#12-foreign-language-interface)
  - [12.1 Overview of the Interface](#121-overview-of-the-interface)
  - [12.2 Linking Foreign Modules](#122-linking-foreign-modules)
  - [12.3 Interface Data Types](#123-interface-data-types)
  - [12.4 The Foreign Include File](#124-the-foreign-include-file)
    - [12.4.1 Argument Passing and Control](#1241-argument-passing-and-control)
    - [12.4.2 Atoms and functors](#1242-atoms-and-functors)
    - [12.4.3 Input and output](#1243-input-and-output)
    - [12.4.4 Analysing Terms via the Foreign Interface](#1244-analysing-terms-via-the-foreign-interface)
    - [12.4.5 Constructing Terms](#1245-constructing-terms)
    - [12.4.6 Unifying data](#1246-unifying-data)
    - [12.4.7 Convenient functions to generate Prolog exceptions](#1247-convenient-functions-to-generate-prolog-exceptions)
    - [12.4.8 Foreign language wrapper support functions](#1248-foreign-language-wrapper-support-functions)
    - [12.4.9 Serializing and deserializing Prolog terms](#1249-serializing-and-deserializing-prolog-terms)
    - [12.4.10 BLOBS: Using atoms to store arbitrary binary data](#12410-blobs-using-atoms-to-store-arbitrary-binary-data)
    - [12.4.11 Exchanging GMP numbers](#12411-exchanging-gmp-numbers)
    - [12.4.12 Calling Prolog from C](#12412-calling-prolog-from-c)
      - [12.4.12.1 Predicate references](#124121-predicate-references)
      - [12.4.12.2 Initiating a query from C](#124122-initiating-a-query-from-c)
    - [12.4.13 Discarding Data](#12413-discarding-data)
    - [12.4.14 String buffering](#12414-string-buffering)
    - [12.4.15 Foreign Code and Modules](#12415-foreign-code-and-modules)
    - [12.4.16 Prolog exceptions in foreign code](#12416-prolog-exceptions-in-foreign-code)
    - [12.4.17 Catching Signals (Software Interrupts)](#12417-catching-signals-software-interrupts)
    - [12.4.18 Miscellaneous](#12418-miscellaneous)
    - [12.4.19 Errors and warnings](#12419-errors-and-warnings)
    - [12.4.20 Environment Control from Foreign Code](#12420-environment-control-from-foreign-code)
    - [12.4.21 Querying Prolog](#12421-querying-prolog)
    - [12.4.22 Registering Foreign Predicates](#12422-registering-foreign-predicates)
    - [12.4.23 Foreign Code Hooks](#12423-foreign-code-hooks)
    - [12.4.24 Storing foreign data](#12424-storing-foreign-data)
    - [12.4.25 Embedding SWI-Prolog in other applications](#12425-embedding-swi-prolog-in-other-applications)
  - [12.5 Linking embedded applications using swipl-ld](#125-linking-embedded-applications-using-swipl-ld)
  - [12.6 The Prolog 'home' directory](#126-the-prolog-home-directory)
  - [12.7 Example of Using the Foreign Interface](#127-example-of-using-the-foreign-interface)
  - [12.8 Notes on Using Foreign Code](#128-notes-on-using-foreign-code)
  - [12.9 Foreign access to Prolog IO streams](#129-foreign-access-to-prolog-io-streams)

## 12. Foreign Language Interface

SWI-Prolog offers a powerful interface to C [Kernighan & Ritchie, 1978]. The main design objectives of the foreign language interface are flexibility and performance. A foreign predicate is a C function that has the same number of arguments as the predicate represented. C functions are provided to analyse the passed terms, convert them to basic C types as well as to instantiate arguments using unification. Non-deterministic foreign predicates are supported, providing the foreign function with a handle to control backtracking.

C can call Prolog predicates, providing both a query interface and an interface to extract multiple solutions from a non-deterministic Prolog predicate. There is no limit to the nesting of Prolog calling C, calling Prolog, etc. It is also possible to write the 'main' in C and use Prolog as an embedded logical engine.

## 12.4.12 Calling Prolog from C

The Prolog engine can be called from C. There are two interfaces for this. For the first, a term is created that could be used as an argument to [call/1], and then [PL_call()] is used to call Prolog. This system is simple, but does not allow to inspect the different answers to a non-deterministic goal and is relatively slow as the runtime system needs to find the predicate. The other interface is based on [PL_open_query()], [PL_next_solution()], and [PL_cut_query()] or [PL_close_query()]. This mechanism is more powerful, but also more complicated to use.

### 12.4.12.1 Predicate references

This section discusses the functions used to communicate about predicates. Though a Prolog predicate may be defined or not, redefined, etc., a Prolog predicate has a handle that is neither destroyed nor moved. This handle is known by the type `predicate_t`.

**predicate_t PL_pred(functor_t f, module_t m)**

Return a handle to a predicate for the specified name/arity in the given module. If the module argument m is `NULL`, the current context module is used. If the target predicate does not exist a handle to a new *undefined* predicate is returned. The predicate may fail, returning `(predicate_t)0` after setting a resource exception, if the target module has a limit on the `program_space`, see [set_module/1]. Currently aborts the process with a *fatal error* when out of memory. Future versions may raise a resource exception and return `(predicate_t)0`.

**predicate_t PL_predicate(const char *name, int arity, const char* module)**

Same as [PL_pred()], but provides a more convenient interface to the C programmer. If the module argument module is `NULL`, the current context module is used. The `predicate_t` handle may be stored as global data and reused for future queries. [PL_predicate()] involves 5 hash lookups (two to get the atoms, one to get the module, one to get the functor and the final one to get the predicate associated with the functor in the module) as illustrated below.

```c
static predicate_t p = 0;

...
if ( !p )
  p = PL_predicate("is_a", 2, "database");
```

Note that [PL_cleanup()] invalidates the predicate handle. Foreign libraries that use the above mechanism must implement the module **uninstall()** function to clear the `predicate_t` global variable.

**bool PL_predicate_info(predicate_t p, atom_t *n, size_t *a, module_t *m)**

Return information on the predicate p. The name is stored over n, the arity over a, while m receives the definition module. Note that the latter need not be the same as specified with [PL_predicate()]. If the predicate is imported into the module given to [PL_predicate()], this function will return the module where the predicate is defined. Any of the arguments n, a and m can be `NULL`. Currently always returns `TRUE`.

### 12.4.12.2 Initiating a query from C

This section discusses the functions for creating and manipulating queries from C. Note that a foreign context can have at most one active query. This implies that it is allowed to make strictly nested calls between C and Prolog (Prolog calls C, calls Prolog, calls C, etc.), but it is **not** allowed to open multiple queries and start generating solutions for each of them by calling [PL_next_solution()]. Be sure to call [PL_cut_query()] or [PL_close_query()] on any query you opened before opening the next or returning control back to Prolog. Failure to do so results in "undefined behavior" (typically, a crash).

**qid_t PL_open_query(module_t ctx, int flags, predicate_t p, term_t +t0)**

Opens a query and returns an identifier for it. ctx is the *context module* of the goal. When `NULL`, the context module of the calling context will be used, or `user` if there is no calling context (as may happen in embedded systems). Note that the context module only matters for *meta-predicates*. See [meta_predicate/1], [context_module/1] and [module_transparent/1]. The term reference t0 is the first of a vector of term references as returned by [PL_new_term_refs(n)]. Raise a resource exception and returns `(qid_t)0` on failure.

Every use of [PL_open_query()] must have a corresponding call to [PL_cut_query()] or [PL_close_query()] before the foreign predicate returns either `TRUE` or `FALSE`.

The flags arguments provides some additional options concerning debugging and exception handling. It is a bitwise *or* of the following values below. Note that exception propagation is defined by the flags `PL_Q_NORMAL`, `PL_Q_CATCH_EXCEPTION` and `PL_Q_PASS_EXCEPTION`. Exactly one of these flags must be specified (if none of them is specified, the behavior is as if `PL_Q_NODEBUG` is specified).

**`PL_Q_NORMAL`**

Normal operation. It is named "normal" because it makes a call to Prolog behave as it did before exceptions were implemented, i.e., an error (now uncaught exception) triggers the debugger. See also the Prolog flag [debug_on_error]. This mode is still useful when calling Prolog from C if the C code is not willing to handle exceptions.

**`PL_Q_NODEBUG`**

Switch off the debugger while executing the goal. This option is used by many calls to hook-predicates to avoid tracing the hooks. An example is [print/1] calling [portray/1] from foreign code. This is the default if flags is `0`.

**`PL_Q_CATCH_EXCEPTION`**

If an exception is raised while executing the goal, make it available by calling `[PL_exception(qid)]`, where `qid` is the `qid_t` returned by [PL_open_query()]. The exception is implicitly cleared from the environment when the query is closed and the exception term returned from `[PL_exception(qid)]` becomes invalid. Use `PL_Q_PASS_EXCEPTION` if you wish to propagate the exception.

**`PL_Q_PASS_EXCEPTION`**

As `PL_Q_CATCH_EXCEPTION`, making the exception on the inner environment available using `[PL_exception(0)]` in the parent environment. If [PL_next_solution()] returns `FALSE`, you must call [PL_cut_query()] or [PL_close_query()]. After that you may verify whether failure was due to logical failure of the called predicate or an exception by calling `[PL_exception(0)]`. If the predicate failed due to an exception you should return with `FALSE` from the foreign predicate or call [PL_clear_exception()] to clear it. If you wish to process the exception in C, it is advised to use `PL_Q_CATCH_EXCEPTION` instead, but only if you have no need to raise an exception or re-raise the caught exception.

Note that `PL_Q_PASS_EXCEPTION` is used by the debugger to decide whether the exception is *caught*. If there is no matching [catch/3] call in the current query and the query was started using `PL_Q_PASS_EXCEPTION` the debugger searches the parent queries until it either finds a matching [catch/3], a query with `PL_Q_CATCH_EXCEPTION` (in which case it considers the exception handled by C) or the top of the query stack (in which case it considers the exception *uncaught*). Uncaught exceptions use the `library(library(prolog_stack))` to add a backtrace to the exception and start the debugger as soon as possible if the Prolog flag [debug_on_error] is `true`.

**`PL_Q_ALLOW_YIELD`**

Support the `I_YIELD` instruction for engine-based coroutining. See $engine_yield/2 in `boot/init.pl` for details.

**`PL_Q_TRACE_WITH_YIELD`**

Allows for implementing a *yield* based debugger. See [section 12.4.1.3]

**`PL_Q_EXT_STATUS`**

Make [PL_next_solution()] return extended status. Instead of only `TRUE` or `FALSE` extended status as illustrated in the following table:

| Extended | Normal | Description |
|----------|--------|-------------|
| PL_S_NOT_INNER | FALSE | [PL_next_solution()] may only be called on the innermost query |
| PL_S_EXCEPTION | FALSE | Exception available through [PL_exception()] |
| PL_S_FALSE | FALSE | Query failed |
| PL_S_TRUE | TRUE | Query succeeded with choicepoint |
| PL_S_LAST | TRUE | Query succeeded without choicepoint |
| PL_S_YIELD | n/a | Query was yielded. See [section 12.4.1.2] |
| PL_S_YIELD_DEBUG | n/a | Yielded on behalf of the debugger. See [section 12.4.1.3] |

[PL_open_query()] can return the query identifier `0` if there is not enough space on the environment stack (and makes the exception available through `[PL_exception(0)]`). This function succeeds, even if the referenced predicate is not defined. In this case, running the query using [PL_next_solution()] may return an existence_error. See [PL_exception()].

The example below opens a query to the predicate is_a/2 to find the ancestor of 'me'. The reference to the predicate is valid for the duration of the process or until [PL_cleanup()] is called (see [PL_predicate()] for details) and may be cached by the client.

```c
char *
ancestor(const char *me)
{ term_t a0 = PL_new_term_refs(2);
  static predicate_t p;

  if ( !p )
    p = PL_predicate("is_a", 2, "database");

  PL_put_atom_chars(a0, me);
  PL_open_query(NULL, PL_Q_PASS_EXCEPTION, p, a0);
  ...
}
```

**int PL_next_solution(qid_t qid)**

Generate the first (next) solution for the given query. The return value is `TRUE` if a solution was found, or `FALSE` to indicate the query could not be proven. This function may be called repeatedly until it fails to generate all solutions to the query. The return value `PL_S_NOT_INNER` is returned if qid is not the innermost query.

If the [PL_open_query()] had the flag `PL_Q_EXT_STATUS`, there are additional return values (see [section 12.4.1.2]).

**int PL_cut_query(qid_t qid)**

Discards the query, but does not delete any of the data created by the query. It just invalidates qid, allowing for a new call to [PL_open_query()] in this context. [PL_cut_query()] may invoke cleanup handlers (see [setup_call_cleanup/3]) and therefore may experience exceptions. If an exception occurs the return value is `FALSE` and the exception is accessible through `[PL_exception(0)]`.

An example of a handler that can trigger an exception in [PL_cut_query()] is:

```prolog
test_setup_call_cleanup(X) :-
    setup_call_cleanup(
        true,
        between(1, 5, X),
        throw(error)).
```

where [PL_next_solution()] returns `TRUE` on the first result and the `throw(error)` will only run when [PL_cut_query()] or [PL_close_query()] is run. On the other hand, if the goal in [setup_call_cleanup/3] has completed (failure, exception, deterministic success), the cleanup handler will have done its work before control gets back to Prolog and therefore [PL_next_solution()] will have generated the exception. The return value `PL_S_NOT_INNER` is returned if qid is not the innermost query.

**int PL_close_query(qid_t qid)**

As [PL_cut_query()], but all data and bindings created by the query are destroyed as if the query is called as `\+ \+ Goal`. This reduces the need for garbage collection, but also rewinds side effects such as setting global variables using [b_setval/2]. The return value `PL_S_NOT_INNER` is returned if qid is not the innermost query.

**qid_t PL_current_query(void)**

Returns the query id of the current query or `0` if the current thread is not executing any queries.

**PL_engine_t PL_query_engine(qid_t qid)**

Return the engine to which qid belongs. Note that interacting with a query or the Prolog terms associated with a query requires the engine to be *current*. See [PL_set_engine()].

**term_t PL_query_arguments(qid_t qid)**

Return a `term_t` handle to the first argument of the main goal of the query qid. This allows for enumerating a query and acting on the binding of one of the arguments without additional context. Note that the returned `term_t` is *not* the same handle that was used in [PL_open_query()] to pass the arguments. The content of the returned vector, however, is the same.

**void* PL_set_query_data(qid_t qid, unsigned int offset, void* data)**

**void* PL_query_data(qid_t qid, unsigned int offset)**

Associate user data with a query. offset must be smaller than `PL_MAX_QUERY_DATA` (currently 2). [PL_set_query_data()] returns the old value.

**bool PL_call_predicate(module_t m, int flags, predicate_t pred, term_t +t0)**

Shorthand for [PL_open_query()], [PL_next_solution()], [PL_cut_query()], generating a single solution. The arguments are the same as for [PL_open_query()], the return value is the same as [PL_next_solution()].

**bool PL_call(term_t t, module_t m)**

Call term t just like the Prolog predicate [once/1]. t is called in the module m, or in the context module if m == NULL. Returns `TRUE` if the call succeeds, `FALSE` otherwise. If the goal raises an exception the return value is `FALSE` and the exception term is available using [PL_exception(0)].

## Complete Documentation Index

The full SWI-Prolog C interface documentation is available in the following files:

| Section | File | Description |
|---------|------|-------------|
| 12.4.1 | [foreign-control.md](foreign-control.md) | Argument Passing and Control |
| 12.4.2 | [foreign-atoms.md](foreign-atoms.md) | Atoms and functors |
| 12.4.3 | [input-and-output.md](input-and-output.md) | Input and output |
| 12.4.4 | [foreign-term-analysis.md](foreign-term-analysis.md) | Analysing Terms via the Foreign Interface |
| 12.4.5 | [foreign-term-construct.md](foreign-term-construct.md) | Constructing Terms |
| 12.4.6 | [foreign-unify.md](foreign-unify.md) | Unifying data |
| 12.4.7 | [cerror.md](cerror.md) | Convenient functions to generate Prolog exceptions |
| 12.4.8 | [pl-cvt-functions.md](pl-cvt-functions.md) | Foreign language wrapper support functions |
| 12.4.9 | [foreign-serialize.md](foreign-serialize.md) | Serializing and deserializing Prolog terms |
| 12.4.10 | [blob.md](blob.md) | BLOBS: Using atoms to store arbitrary binary data |
| 12.4.11 | [gmpforeign.md](gmpforeign.md) | Exchanging GMP numbers |
| 12.4.12 | **calling_from_c.md** | **Calling Prolog from C** (this file) |
| 12.4.13 | [foreign-discard-term-t.md](foreign-discard-term-t.md) | Discarding Data |
| 12.4.14 | [foreign-strings.md](foreign-strings.md) | String buffering |
| 12.4.15 | [foreign-modules.md](foreign-modules.md) | Foreign Code and Modules |
| 12.4.16 | [foreign-exceptions.md](foreign-exceptions.md) | Prolog exceptions in foreign code |
| 12.4.17 | [csignal.md](csignal.md) | Catching Signals (Software Interrupts) |
| 12.4.18 | [foreign-misc.md](foreign-misc.md) | Miscellaneous |
| 12.4.19 | [foreign-print-warning.md](foreign-print-warning.md) | Errors and warnings |
| 12.4.20 | [foreign-control-prolog.md](foreign-control-prolog.md) | Environment Control from Foreign Code |
| 12.4.21 | [foreign-query.md](foreign-query.md) | Querying Prolog |
| 12.4.22 | [foreign-register-predicate.md](foreign-register-predicate.md) | Registering Foreign Predicates |
| 12.4.23 | [foreign-hooks.md](foreign-hooks.md) | Foreign Code Hooks |
| 12.4.24 | [foreigndata.md](foreigndata.md) | Storing foreign data |
| 12.4.25 | [embedded.md](embedded.md) | Embedding SWI-Prolog in other applications |

## Additional Resources

- [SWI-Prolog Homepage](http://www.swi-prolog.org)
- [Complete Reference Manual](https://www.swi-prolog.org/pldoc/refman/)
- [Foreign Language Interface Overview](https://www.swi-prolog.org/pldoc/man?section=foreign)
- [C++ Interface (pl2cpp package)](https://www.swi-prolog.org/pldoc/doc_for?object=section('packages/pl2cpp.html'))

## Notes

- This documentation is based on SWI-Prolog version 10.1.5-7-gb9f48137e
- The C interface is not standardized across Prolog implementations
- For C++ interface, see the [pl2cpp package](https://www.swi-prolog.org/pldoc/doc_for?object=section('packages/pl2cpp.html'))
- Modern C references: [Modern C by Jens Gustedt](https://modernc.gforge.inria.fr/) (C17 standard)