PICS=$(patsubst %.uml,%.png,$(wildcard doc/*.uml))

.PHONY: test
test:
	rebar3 do compile, dialyzer, eunit

doc/%.png: doc/%.uml
	plantuml -tsvg $<

.PHONY: doc
doc: $(PICS)
	rebar3 edoc

.PHONY: clean
clean:
	rm -rf _build

.PHONY: hex-publish
hex-publish: clean
	rebar3 as dev hex publish
