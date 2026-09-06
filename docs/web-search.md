# Web Search & Fetch

The `native-web-search` tool exposes `web_search` and `web_fetch`. Each instance
has an ordered list of one to three distinct providers: Brave, Tavily, TinyFish,
Exa, and Firecrawl. Configure the list in General and the corresponding API keys
in Credentials. Credentials are stored as managed secrets and stay associated
with their provider when the list is reordered. API endpoint overrides are
available for proxies and testing.

Search returns ranked titles, URLs, and snippets. The existing Brave arguments
remain supported. A provider that cannot honor an explicitly supplied filter is
skipped with a warning. In particular, nonzero Brave offsets and `safesearch`
require Brave; `search_lang` works with Brave and TinyFish, and `country` works
with Brave, TinyFish, Exa, and Firecrawl.

Fetch accepts `urls` containing one to ten HTTP(S) URLs. It reads the supplied
URLs without crawling linked pages. Tavily uses advanced Markdown extraction,
TinyFish uses its clean Markdown Fetch API, Exa uses compact live contents, and
Firecrawl enables both main-content and additional Markdown cleaning. Brave
uses the built-in Web Reader and does not require an API key for fetch. This
supports HTML, PDF, DOCX, and text using the same extraction and cache as the
standalone Web Reader; the complete extracted document is returned within the
configured output limit. The built-in reader does not render JavaScript.

Every invocation starts at the first provider. A failed request proceeds to the
next provider without hidden HTTP retries. Valid empty search results stop the
chain. For fetch, empty content is a failure, and only failed URLs proceed to
the next provider. A partially successful fetch returns its successful pages
and reports the remaining failures. Each URL has at most one attempt per
provider. Fetches of different URLs run concurrently within a provider stage.
The search/fetch attempt deadlines default to 30/150 seconds.

Warnings precede content in the model-visible result. Structured `attempts`
record the provider, actual backend (`web_reader` for Brave fetch), operation,
URL where applicable, status, duration, and sanitized error. These diagnostics
survive output truncation. Provider credentials and raw error bodies are never
included. Complete failure sets `isError`; partial success does not.

On startup, after managed-secret maintenance, legacy `native-brave-search`
instances are migrated in place through Ash actions. Identity, bindings,
permissions, function overrides, custom settings, and keys are preserved.
Failed migrations are retried on the next startup, and the legacy type retains
an execution compatibility adapter. Restore the pre-upgrade database backup
before reverting to a release that does not recognize `native-web-search`.
