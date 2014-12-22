module I18n
  module Backend
    class SphDb
      (class << self; self; end).class_eval { public :include }
      module Implementation
        include Base

        def initialized?
          @initialized ||= false
        end

        # Stores translations for the given locale in memory.
        def store_translations(locale, data, options = {})
          locale = locale.to_sym
          translations[locale] ||= {}
          data = data.deep_symbolize_keys
          translations[locale].deep_merge!(data)
        end

        # Get available locales from the translations hash
        def available_locales
          init_translations unless initialized?
          translations.inject([]) do |locales, (locale, data)|
            locales << locale unless (data.keys - [:i18n]).empty?
            locales
          end
        end

        # Clean up translations hash and set initialized to false on reload!
        def reload!
          @initialized = false
          @translations = nil
          super
        end

      protected

        def init_translations
          load_translations
          @initialized = true
        end

        def translations
          @translations ||= {}
        end

        # Looks up a translation from the db. Returns nil if
        # eiher key is nil, or locale, scope or key do not exist as a key in the
        # nested translations hash. Splits keys or scopes containing dots
        # into multiple keys, i.e. <tt>currency.format</tt> is regarded the same as
        # <tt>%w(currency format)</tt>.
        def lookup(locale, key, scope = [], options = {})

          init_translations unless initialized?
          result = nil
          _locale = ::Locale.first(:code => locale)
          key = pluralizer(_locale, key, options[:count])
          value = _locale.translations.first(:code => key)
          result = value.value unless value.nil?
          result = options[:default] if !value.nil? && value.value == key && options[:default]
          return result unless value.nil? || value.value == key
          
          # check devise messages for remaining keys
          result = _locale.translations.first(:code => "devise.sessions.#{key}")
          return result.value unless result.nil?

          # fall back on yaml file if no object is found in db
          keys = I18n.normalize_keys(locale, key, scope, options[:separator])
          keys.inject(translations) do |result, _key|
            return nil unless result.is_a?(Hash) && result.has_key?(_key)
            result = result[_key]
            result = resolve(locale, _key, result, options.merge(:scope => nil)) if result.is_a?(Symbol)
            result = options[:default] if options[:default] && result.nil?
            result
          end
          
        end
        
        def pluralizer(locale, key, count)
          return key unless key.class.to_s == "String" && count
          if count == 0
            _key = "#{key}.zero"
          elsif count == 1
            _key = "#{key}.one"
          elsif count > 1
            _key = "#{key}.other" 
          else
            
          end
          return _key unless locale.translations.first(:code => key).nil?
          key
        end
        
      end

        # Evaluates defaults.
        # If given subject is an Array, it walks the array and returns the
        # first translation that can be resolved. Otherwise it returns the
        # last string value in the Array.
        def default(locale, object, subject, options = {})
          options = options.dup.reject { |key, value| key == :default }
          case subject
          when Array
            subject.count - 1
            subject.each do |item|
              result = resolve(locale, object, item, options) #and return result
              result = lookup(locale, result, options[:scope], options)
              return result if result.is_a?(String)
              return result = resolve(locale, object, item, options) if item == subject.last
            end and nil
          else
            resolve(locale, object, subject, options)
          end
        end


      include Implementation
    end
  end
end