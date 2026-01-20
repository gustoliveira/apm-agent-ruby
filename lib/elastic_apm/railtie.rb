# Licensed to Elasticsearch B.V. under one or more contributor
# license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright
# ownership. Elasticsearch B.V. licenses this file to you under
# the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# frozen_string_literal: true

require 'elastic_apm/spies/rack_middleware'

module ElasticAPM
  # @api private
  class Railtie < ::Rails::Railtie
    config.elastic_apm = ActiveSupport::OrderedOptions.new

    Config.schema.each do |key, args|
      next unless args.length > 1
      config.elastic_apm[key] = args[:default]
    end

    initializer 'elastic_apm.initialize' do |app|
      config = Config.new(app.config.elastic_apm.merge(app: app)).tap do |c|
        # Prepend Rails.root to log_path if present
        if c.log_path && !c.log_path.start_with?('/')
          c.log_path = ::Rails.root.join(c.log_path)
        end
      end

      if Rails.start(config)
        app.middleware.insert 0, Middleware
      end
    end

    initializer 'elastic_apm.instrument_middlewares', after: :initialize_logger do |app|
      # We use a separate initializer to ensure it runs, but we still wait until after_initialize
      # for the actual work because the middleware stack might change during boot.
    end

    # Instrument middlewares after the app is fully initialized
    config.after_initialize do |app|
      next unless ElasticAPM.running?
      next unless ElasticAPM.agent.config.instrument_rack_middlewares

      Railtie.instrument_middlewares(app)
    end

    class << self
      def instrument_middlewares(app)
        last_middleware = nil
        middlewares = app.middleware.to_a
        
        # Find the last instrumentable middleware
        middlewares.reverse_each do |m|
          klass = m.respond_to?(:klass) ? m.klass : m
          if klass.is_a?(Class) && !Spies::RackMiddlewareSpy.should_skip?(klass)
            last_middleware = klass
            break
          end
        end
        
        Spies::RackMiddlewareSpy.last_middleware_class = last_middleware

        app.middleware.each do |middleware|
          klass = middleware.respond_to?(:klass) ? middleware.klass : middleware
          next unless klass.is_a?(Class)

          Spies::RackMiddlewareSpy.instrument_middleware(klass)
        end
      end
    end
  end
end
