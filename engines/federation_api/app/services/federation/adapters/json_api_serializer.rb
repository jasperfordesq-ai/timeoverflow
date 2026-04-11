# Standalone JSON:API document serializer/deserializer.
#
# Builds and parses JSON:API (https://jsonapi.org/) documents without
# any gem dependencies. Used by JsonApiAdapter for Komunitin compatibility.
#
# All methods are stateless module functions — no instantiation needed.
#
module Federation
  module Adapters
    module JsonApiSerializer
      # Serialize a single resource into JSON:API format.
      #
      # @param type [String, Symbol] the resource type (e.g., "accounts", "transfers")
      # @param id [String, Integer] the resource identifier
      # @param attributes [Hash] the resource attributes
      # @param relationships [Hash] optional relationship data
      # @return [Hash] a JSON:API document
      def self.serialize_resource(type, id, attributes, relationships: {})
        doc = { data: { type: type.to_s, id: id.to_s, attributes: attributes } }
        doc[:data][:relationships] = relationships unless relationships.empty?
        doc
      end

      # Serialize a collection of resources into JSON:API format.
      #
      # @param type [String, Symbol] the resource type
      # @param items [Array<Hash>] array of hashes, each with an :id key
      # @param meta [Hash] optional meta information
      # @return [Hash] a JSON:API document with a data array
      def self.serialize_collection(type, items, meta: {})
        {
          data: items.map { |item|
            item = item.dup
            id = item.delete(:id) || item.delete("id")
            { type: type.to_s, id: id.to_s, attributes: item }
          },
          meta: meta
        }
      end

      # Serialize one or more errors into JSON:API error format.
      #
      # @param title [String] short error title
      # @param detail [String] human-readable error detail
      # @param status [String, Integer] HTTP status code
      # @param code [String, nil] optional application-specific error code
      # @return [Hash] a JSON:API errors document
      def self.serialize_error(title:, detail:, status:, code: nil)
        error = { status: status.to_s, title: title, detail: detail }
        error[:code] = code if code
        { errors: [error] }
      end

      # Deserialize a JSON:API document into flat hash(es).
      #
      # For a single resource, returns a flat Hash with "id", "type", and
      # all attributes merged in. Relationships are flattened to "_id" / "_ids" keys.
      #
      # For a collection, returns an Array of such hashes.
      #
      # @param document [Hash] a parsed JSON:API document
      # @return [Hash, Array<Hash>] flattened resource(s)
      def self.deserialize(document)
        return {} unless document.is_a?(Hash)
        data = document["data"] || document[:data]
        return {} unless data

        if data.is_a?(Array)
          data.map { |resource| flatten_resource(resource) }
        else
          flatten_resource(data)
        end
      end

      # @api private
      def self.flatten_resource(resource)
        return resource unless resource.is_a?(Hash)
        result = (resource["attributes"] || resource[:attributes] || {}).dup
        result["id"] = resource["id"] || resource[:id]
        result["type"] = resource["type"] || resource[:type]

        # Flatten relationships into foreign-key style keys
        rels = resource["relationships"] || resource[:relationships] || {}
        rels.each do |key, rel_data|
          linked = rel_data["data"] || rel_data[:data]
          if linked.is_a?(Hash)
            result["#{key}_id"] = linked["id"] || linked[:id]
            result["#{key}_type"] = linked["type"] || linked[:type]
          elsif linked.is_a?(Array)
            result["#{key}_ids"] = linked.compact.map { |l| l.is_a?(Hash) ? (l["id"] || l[:id]) : l }
          end
        end
        result
      end
      private_class_method :flatten_resource
    end
  end
end
