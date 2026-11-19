# @getpipher/agent-statusline

omp in-pane renderer for [getpipher/agent-statusline](https://github.com/getpipher/agent-statusline)
— the Tern-native statusline plugin. This package is a zero-logic consumer:
it reads the Tern plugin's snapshot file and renders the classic six-row
block (info · prayers · money · quota windows · versions) below the omp
composer, in the same look as the retired `@getpipher/omp-statusline`.

## Install

```sh
omp plugin install @getpipher/agent-statusline
```

Requires the `agent-statusline` Tern plugin to have produced a snapshot at
least once (`<state>/plugin-data/agent-statusline/kv.json`). Outside a
running Tern it renders the last snapshot with a `· stale Xm` chip; before
the first snapshot it renders nothing.

Never install it alongside `@getpipher/omp-statusline` — both register a
`belowEditor` widget.

## License

MIT — see [LICENSE](LICENSE).
