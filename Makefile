PICS=$(patsubst %.uml,%.png,$(wildcard doc/*.uml))

.PHONY: test
test:
	rebar3 do compile, dialyzer, eunit

doc/%.png: doc/%.uml
	plantuml -tsvg $<

.PHONY: doc
doc: $(PICS)
	rebar3 edoc
