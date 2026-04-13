class FederationCcEntry < ActiveRecord::Base
  belongs_to :federation_transaction, optional: true
  belongs_to :organization

  STATES = %w[P V C E X].freeze

  validates :organization_id, presence: true
  validates :transaction_uuid, presence: true,
            uniqueness: { scope: :organization_id }
  validates :payer, presence: true
  validates :payee, presence: true
  validates :quant, presence: true, numericality: { greater_than: 0 }, unless: -> { state == "X" }
  validates :quant, presence: true, numericality: { greater_than_or_equal_to: 0 }, if: -> { state == "X" }
  validates :state, presence: true, inclusion: { in: STATES }

  scope :completed, -> { where(state: "C") }
  scope :pending, -> { where(state: "P") }
  scope :validated, -> { where(state: "V") }
  scope :for_organization, ->(org_id) { where(organization_id: org_id) }
  scope :involving, ->(account_path) { where("payer = ? OR payee = ?", account_path, account_path) }

  validate :payer_differs_from_payee
  validate :valid_state_transition, if: :state_changed?

  # Valid state transitions per Credit Commons protocol:
  #   P (Pending) -> V (Validated), E (Error), X (eXpunged)
  #   V (Validated) -> C (Completed), E (Error), X (eXpunged)
  #   C (Completed) -> X (eXpunged)
  #   E (Error) -> P (Pending), X (eXpunged)
  #   X (eXpunged) -> [] (terminal)
  VALID_TRANSITIONS = {
    "P" => %w[V E X],
    "V" => %w[C E X],
    "C" => %w[X],
    "E" => %w[P X],
    "X" => []
  }.freeze

  private

  def valid_state_transition
    return if new_record?
    old_state = state_was
    allowed = VALID_TRANSITIONS[old_state] || []
    unless allowed.include?(state)
      errors.add(:state, "cannot transition from '#{old_state}' to '#{state}'")
    end
  end

  def payer_differs_from_payee
    if payer.present? && payee.present? && payer == payee
      errors.add(:payee, "cannot be the same as payer")
    end
  end
end
