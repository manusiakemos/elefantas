.PHONY: vendor project test itest itest-up itest-down app clean

PACKAGES := Packages/PGKit Packages/ElefantasCore

vendor:
	./scripts/build-libpq.sh

project: vendor
	xcodegen generate

test: vendor
	@for p in $(PACKAGES); do echo "==> swift test ($$p)"; (cd $$p && swift test) || exit 1; done

itest-up:
	docker compose -f docker/compose.yml up -d --wait

itest-down:
	docker compose -f docker/compose.yml down -v

# Runs the integration tests against every server in docker/compose.yml.
itest: vendor itest-up
	@for port in 54317 54318 54319; do \
	  for p in $(PACKAGES); do \
	    echo "==> itest ($$p) against port $$port"; \
	    (cd $$p && ELEFANTAS_ITEST=1 ELEFANTAS_ITEST_PORT=$$port swift test) || exit 1; \
	  done; \
	done

app: project
	xcodebuild -project Elefantas.xcodeproj -scheme Elefantas -configuration Debug \
	  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData build

clean:
	rm -rf build .build Packages/*/.build Elefantas.xcodeproj
