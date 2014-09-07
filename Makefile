VERSION=1.1.0
NAME=log-shipper
PREFIX=/usr/share/$(NAME)

build: npm js deb

npm:
	npm install

js:
	coffee -c src/index.coffee

deb:
	fpm -s dir -t deb -a all -n $(NAME) -v $(VERSION) \
	--exclude '*.coffee' \
	--deb-upstart config/$(NAME) \
	--before-remove scripts/prerm \
	--before-install scripts/preinst \
	--after-install scripts/postinst \
	--deb-user $(NAME) \
	src/=$(PREFIX)/ \
	config/$(NAME).json=/etc/$(NAME)/$(NAME).example.json
	mv $(NAME)_$(VERSION)_all.deb build/
