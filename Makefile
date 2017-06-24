.PHONY: build clean publish serve

build: clean
	cobalt build


# .nojekyll needed because reasons: https://github.com/blog/2289-publishing-with-github-pages-now-as-easy-as-1-2-3
publish:
	@git branch -D master
	@rm -rf build && echo "Removed ./build"
	@cobalt build && echo "Generated static site"
	@cobalt --log-level trace import --branch master && echo "Imported site into master branch"
	@echo "Waiting two seconds for import to finish" && sleep 2
	@git checkout master
	@touch .nojekyll
	@git add .nojekyll
	@git commit -m "Github Pages integration" && echo "created .nojekyll"
	@git push -u -f origin master && echo "pushed master branch"
	@git checkout source && echo "switched to source branch"

serve:
	devd -w build /=build

clean:
	rm -rf build/
