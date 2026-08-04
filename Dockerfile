name=Dockerfile
FROM mediawiki:1.39

# Install utilities used when adding extensions or building assets
USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends git unzip zip ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Prepare directories (create them so builds don't fail if not present in context)
RUN mkdir -p /var/www/html/extensions /var/www/html/skins

# OPTIONAL: copy your custom extensions/skins/LocalSettings into the image.
# If you do not store these in the repo, remove or comment out the following COPY lines.
# COPY ./extensions/ /var/www/html/extensions/
# COPY ./skins/ /var/www/html/skins/
# LocalSettings.php usually contains secrets — do NOT commit secrets to the repo.
# If you include a LocalSettings.php in the repo for testing, uncomment the line below:
# COPY ./LocalSettings.php /var/www/html/LocalSettings.php

# Set ownership so web server can write to images and extensions (uploads etc.)
RUN chown -R www-data:www-data /var/www/html/extensions /var/www/html/skins /var/www/html/images || true

# Switch back to the default user the base image expects
USER www-data

EXPOSE 80

# Use the base image's default command (runs Apache/PHP-FPM as appropriate)
# The mediawiki base image already defines the correct CMD; no override needed.