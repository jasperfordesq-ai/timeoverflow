class FederationCcNodeConfig < ActiveRecord::Base
  belongs_to :organization, optional: true

  validates :node_slug, presence: true, uniqueness: true,
            format: { with: /\A[0-9a-z][0-9a-z-]{1,13}[0-9a-z]\z/, message: "must be 3-15 lowercase alphanumeric characters, hyphens allowed in middle" }
  validates :exchange_rate, numericality: { greater_than: 0 }
  validates :validated_window, numericality: { greater_than: 0 }

  def self.for(organization)
    org_id = organization.is_a?(Integer) ? organization : organization.id
    find_or_create_by!(organization_id: org_id) do |config|
      # Truncate to fit 15-char limit: "to-" prefix + org_id (max 12 chars)
      config.node_slug = "to-#{org_id}"[0, 15]
      config.currency_format = "%s hours"
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(organization_id: org_id)
  end

  def root_node?
    parent_node_url.blank?
  end

  def build_about_response
    org = Organization.find_by(id: organization_id)
    {
      format: currency_format,
      rate: exchange_rate.to_f,
      absolute_path: [node_slug],
      validated_window: validated_window,
      trades: FederationTransaction.where(organization_id: organization_id).completed.count,
      traders: FederationTransaction.where(organization_id: organization_id).completed.select(:remote_user_identifier).distinct.count,
      volume: (FederationTransaction.where(organization_id: organization_id).completed.sum(:amount).to_f / 3600.0 * exchange_rate.to_f).round(2),
      accounts: (org ? org.members.active.count : 0)
    }
  end
end
