class User
  include DataMapper::Resource
  
  class NoDefaultSubscriptionPlanError < StandardError; end
  
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, 
         :validatable, :encryptable, :confirmable

  property :id,                       Serial
  property :lock,                     Boolean,  :default => false

  property :invitation_sent_at,       DateTime
  property :invitation_token,         String, :index => true, :length => 128

  property :created_at,               DateTime
  property :updated_at,               DateTime
  property :completed_signup_at,      DateTime
  property :expires_on,               Date

  property :first_name,               String, :required => true, :length => 256
  property :last_name,                String, :required => true, :length => 256
  property :email,                    String, :required => true, :unique => true, :length => 128
  property :username,                 String, :required => true, :unique => true, :length => 128
  attr_accessor :email_confirmation

  # Validations
  validates_confirmation_of :email

  # Associations
  belongs_to :invitation, :required => false

  has n, :habitats, :constraint => :destroy
  has n, :invitation_batches
  has n, :invitations, :through => :invitation_batches
  
  has 1, :signup_address, "Address", :constraint => :destroy
  has n, :orders, Shop::Order
  has 1, :payment, Shop::Payment, :constraint => :destroy
  accepts_nested_attributes_for :signup_address

  is :subscriber
  is :preferenceable

  # Callbacks
  before :update, :synch_with_subscription

  def self.default_subscription_plan
    scope = SubscriptionScope.for(User)
    scope.default_plan || 
    scope.subscription_plans.visible.ordered.first ||
    raise(NoDefaultSubscriptionPlanError.new("No default subscription plan for Users"))
  end

  def self.active(date=Date.today)
    all(:expires_on.gte => date, :lock => false)
  end

  # Instance Methods
  # Help the controller setup the signup address
  def build_signup_address(attrs={})
    self.signup_address = Address.new(attrs)
  end

  # See if the user has confirmed their account
  # This method is defined in Devise originally, however we need to extend it.
  def active?
    super && (!confirmation_required? || confirmed? || confirmation_period_valid?)
  end

  # We can disable our branding if we have an invitation and our subscription
  # is not the initial subscription or it is no longer a trial
  def can_disable_affiliate_branding?
    !self.invitation.nil? && 
    !self.affiliate.nil? && 
    (!self.subscription.trial? || !self.invitation_subscription?)
  end

  #
  # Run at the completion of the LAST STEP of the signup process
  #
  def complete_signup
    if self.habitats_count < 1
      self.errors.add(:habitats, "User not done if they don't have a habitat")
      false
    else
      self.completed_signup_at ||= Time.now
      if self.save
        self.generate_confirmation_token!
        enqueue_welcome_email
        true
      else
        false
      end
    end
  end

  # Gathers all the todos across all habitats for the digest
  def digest_todos(limit=3)
    self.habitats.todos.todo_instances.system.dashboard.all({
      :completed_on => nil, 
      :due_on.gt => Date.today - Preference.read_value("digest_todo_past_limit", nil, :default => "3").to_i.days,
      :due_on.lt => Date.today + Preference.read_value("digest_todo_future_limit", nil, :default => "14").to_i.days,
      :limit => limit
    })
  end  
  
  # Gathers the todos for the month across all habitats for the monthly digest
  def monthly_digest_todos(limit=10)
    self.habitats.todos.todo_instances.system.dashboard.all({
      :completed_on => nil, 
      :due_on.gt => Date.today - Preference.read_value("digest_todo_past_limit", nil, :default => "3").to_i.days,
      :due_on.lt => Date.today + Preference.read_value("digest_todo_future_limit", nil, :default => "31").to_i.days,
      :limit => limit
    })
  end
  
  def deliver_welcome_email
    WelcomeMailer.welcome_notification(self).deliver
  end

  def display_affiliate_branding?
    self.invitation && self.preference_show_affiliate_branding == "1"
  end

  def enqueue_welcome_email
    Resque.enqueue(UserEmailWorker, self.id, :deliver_welcome_email)
  rescue
    Rails.logger.warn("Update User#enqueue_welcome_email to only catch Redis connection errrors")
  ensure
    true
  end

  # Returns true if the users current subscription expired before today.
  def expired?
    Date.today > self.expires_on
  end
  
  def first_name
    self.attribute_get(:first_name) || self.attribute_get(:email)
  end

  def full_name
    "#{first_name.capitalize} #{last_name.capitalize}"
  end
  
  def generate_confirmation_token!
    self.confirmation_token = User.confirmation_token
    self.save
  end
  
  def habitats_count
    self.habitats.count
  end
  
  def invitation
    Invitation.first(:token => self.invitation_token) 
  end
  
  def invitations_bought
    self.invitation_batches.sum(:number_bought) || 0
  end
  
  def invitations_available
    self.invitation_batches.sum(:available_count) || 0
  end

  def invitation_subscription?
    self.invitation && 
    subscription.subscription_plan_id == self.invitation.subscription_plan_id
  end

  def invited?
    not self.invitation_token.blank?
  end
  
  def last_name
    self.attribute_get(:last_name) || ""
  end
  
  def lock!
    update(:lock => true)
  end
  
  def locked?
    self.lock
  end
  
  # If the subscription plan is standard and they paid and they have an invitation verify the 
  # invitation has marked them as a conversion.
  def mark_invitation_as_converted(type, state)
    if type == :standard && state != :error && self.invitation
      invitation.converted!
    end
  end
  
  def require_trial_billing_info?
    sub = self.subscription
    sub_plan = sub.nil? ? User.default_subscription_plan : sub.subscription_plan 
    sub_plan.require_trial_billing? || true
  end
  
  # Gets called in Subscription#subscriber_callback
  def subscription_callback(type, state)
    self.update(:expires_on => current_subscription.expires_on)
    mark_invitation_as_converted(type, state)
    create_subscription_event_invitation_batch(type, state)
  end
  
  def synch_with_subscription
    if current_subscription
      self.expires_on ||= current_subscription.expires_on
      self.expires_on > current_subscription.expires_on ? current_subscription.update(:expires_on => self.expires_on) :
                                                          self.expires_on = current_subscription.expires_on
    end
  end

  def unlock!
    update(:lock => false)
  end

  def update(attributes)
    card = attributes.delete :shop_payment
    if card
      card.merge!(:user_id => self.id, :subscription_id => subscription.id)
      super
      Shop::Payment.swap(self, card)
    else
      super
    end
  end

  private
  
  def create_subscription_event_invitation_batch(type, state)
    return if state == :error
    s = current_subscription
    sp = current_subscription.subscription_plan
    if s.initial_iteration? && sp.initial_subscription_plan_id
      invitation_batches.create({
        :subscription_plan_id => sp.initial_subscription_plan_id,
        :number_bought => sp.initial_number_subscriptions,
        :expires_on => Date.today + sp.initial_days_until_subscriptions_expire
      })
    elsif type == :standard && sp.recurring_subscription_plan_id
      invitation_batches.create({
        :subscription_plan_id => sp.recurring_subscription_plan_id,
        :number_bought => sp.recurring_number_subscriptions,
        :expires_on => Date.today + sp.recurring_days_until_subscriptions_expire
      })
    end
  end
    
  def confirmation_required?
    false
  end

end

