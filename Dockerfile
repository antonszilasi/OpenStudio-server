# AUTHOR:           Nicholas Long
# DESCRIPTION:      OpenStudio Server Docker Container
# TO_BUILD_AND_RUN: docker-compose up
# NOTES:            Currently this is one big dockerfile and non-optimal.

FROM ubuntu:14.04
MAINTAINER Nicholas Long nicholas.long@nrel.gov

# Install required libaries
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		autoconf \
		bison \
	    build-essential \
		bzip2 \
		ca-certificates \
		curl \
		default-jdk \
		imagemagick \
		gdebi-core \
		git \
		libbz2-dev \
		libcurl4-openssl-dev \
		libgdbm3 \
		libgdbm-dev \
		libglib2.0-dev \
		libncurses-dev \
		libreadline-dev \
		libxml2-dev \
		libxslt-dev \
        libffi-dev \
        libssl-dev \
        libyaml-dev \
        procps \
		ruby \
		tar \
		unzip \
		wget \
		zip \
		zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Build and Install Ruby
#   -- skip installing gem documentation
RUN mkdir -p /usr/local/etc \
	&& { \
		echo 'install: --no-document'; \
		echo 'update: --no-document'; \
	} >> /usr/local/etc/gemrc

ENV RUBY_MAJOR 2.0
ENV RUBY_VERSION 2.0.0-p648
ENV RUBY_DOWNLOAD_SHA256 8690bd6b4949c333b3919755c4e48885dbfed6fd055fe9ef89930bde0d2376f8
ENV RUBYGEMS_VERSION 2.5.2

# some of ruby's build scripts are written in ruby
# we purge this later to make sure our final image uses what we just built
RUN curl -fSL -o ruby.tar.gz "http://cache.ruby-lang.org/pub/ruby/$RUBY_MAJOR/ruby-$RUBY_VERSION.tar.gz" \
	&& echo "$RUBY_DOWNLOAD_SHA256 *ruby.tar.gz" | sha256sum -c - \
	&& mkdir -p /usr/src/ruby \
	&& tar -xzf ruby.tar.gz -C /usr/src/ruby --strip-components=1 \
	&& rm ruby.tar.gz \
	&& cd /usr/src/ruby \
	&& { echo '#define ENABLE_PATH_CHECK 0'; echo; cat file.c; } > file.c.new && mv file.c.new file.c \
	&& autoconf \
	&& ./configure --disable-install-doc --enable-shared \
	&& make -j"$(nproc)" \
	&& make install \
	&& apt-get purge -y --auto-remove $buildDeps \
	&& gem update --system $RUBYGEMS_VERSION \
	&& rm -r /usr/src/ruby

ENV BUNDLER_VERSION 1.11.2

RUN gem install bundler --version "$BUNDLER_VERSION"

# install things globally, for great justice
# and don't create ".bundle" in all our apps
ENV GEM_HOME /usr/local/bundle
ENV BUNDLE_PATH="$GEM_HOME" \
	BUNDLE_BIN="$GEM_HOME/bin" \
	BUNDLE_SILENCE_ROOT_WARNING=1 \
	BUNDLE_APP_CONFIG="$GEM_HOME"
ENV PATH $BUNDLE_BIN:$PATH
RUN mkdir -p "$GEM_HOME" "$BUNDLE_BIN" \
	&& chmod 777 "$GEM_HOME" "$BUNDLE_BIN"

# Install passenger (this also installs nginx)
ENV PASSENGER_VERSION 5.0.25
RUN gem install passenger -v $PASSENGER_VERSION
RUN passenger-install-nginx-module

# Configure the nginx server
RUN mkdir /var/log/nginx
ADD /docker/server/nginx.conf /opt/nginx/conf/nginx.conf


# Run this separate to cache the download
ENV OPENSTUDIO_VERSION 1.10.4
ENV OPENSTUDIO_SHA d32e3e491e

# Download from S3
ENV OPENSTUDIO_DOWNLOAD_BASE_URL https://s3.amazonaws.com/openstudio-builds/$OPENSTUDIO_VERSION
ENV OPENSTUDIO_DOWNLOAD_FILENAME OpenStudio-$OPENSTUDIO_VERSION.$OPENSTUDIO_SHA-Linux.deb
ENV OPENSTUDIO_DOWNLOAD_URL $OPENSTUDIO_DOWNLOAD_BASE_URL/$OPENSTUDIO_DOWNLOAD_FILENAME

# Install gdebi, then download and install OpenStudio, then clean up.
# gdebi handles the installation of OpenStudio's dependencies including Qt5,
# Boost, and Ruby 2.0.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libboost-thread1.55.0 \
    && curl -SLO $OPENSTUDIO_DOWNLOAD_URL \
    && gdebi -n $OPENSTUDIO_DOWNLOAD_FILENAME \
    && rm -f $OPENSTUDIO_DOWNLOAD_FILENAME \
    && rm -rf /usr/local/lib/openstudio-$OPENSTUDIO_VERSION/ruby/2.0/openstudio/sketchup_plugin \
    && rm -rf /var/lib/apt/lists/*

# Add RUBYLIB link for openstudio.rb
ENV RUBYLIB /usr/local/lib/site_ruby/2.0.0
ENV OPENSTUDIO_SERVER 'true'

#### OpenStudio Server Code
# First upload the Gemfile* so that it can cache the Gems -- do this first because it is slow
ADD /bin /opt/openstudio/bin
ADD /server/Gemfile /opt/openstudio/server/Gemfile
WORKDIR /opt/openstudio/server
RUN bundle install --without development test

# Add the app assets and precompile assets. Do it this way so that when the app changes the assets don't
# have to be recompiled everytime
ADD /server/Rakefile /opt/openstudio/server/Rakefile
ADD /server/config/ /opt/openstudio/server/config/
ADD /server/app/assets/ /opt/openstudio/server/app/assets/
ADD /server/lib /opt/openstudio/server/lib

# Now call precompile
RUN mkdir /opt/openstudio/server/log
ENV RAILS_ENV docker
RUN rake assets:precompile

# Bundle app source
ADD /server /opt/openstudio/server
# Run bundle again, because if the user has a local Gemfile.lock it will have been overriden
RUN bundle install --without development test

# Where to save the assets
RUN mkdir -p /opt/openstudio/server/public/assets/analyses && chmod 777 /opt/openstudio/server/public/assets/analyses
RUN mkdir -p /opt/openstudio/server/public/assets/data_points && chmod 777 /opt/openstudio/server/public/assets/data_points

# forward request and error logs to docker log collector

# TODO: How to get logs out of this, mount shared volume?
#RUN ln -sf /dev/stdout /var/log/nginx/access.log
#RUN ln -sf /dev/stderr /var/log/nginx/error.log
RUN chmod 666 /opt/openstudio/server/log/*.log

ADD /docker/server/start-server.sh /usr/local/bin/start-server
RUN chmod +x /usr/local/bin/start-server

CMD ["/usr/local/bin/start-server"]

# Expose ports.
EXPOSE 8080 9090