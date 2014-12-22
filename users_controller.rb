class Admin::UsersController < AdministrationController

  respond_to :html, :json
  before_filter :validate_can_invite, :only => [:new, :create]
  
  def index
    @users = User.all.page(:page => page, :per_page => 20)
    respond_with(:admin, @users)
  end

  def show
    @user = User.get!(params[:id])
    @habitats = @user.habitats.page(:page => page)
    respond_with(:admin, @user)
  end

  def welcome
    @user = User.get!(params[:id])
    @user.enqueue_welcome_email
    respond_with(:admin, @user, :location => admin_user_path(@user))
  end

  def new
    @invitation = Invitation.new
    respond_with(:admin, @invitation)
  end

  def create
    @invitation = Invitation.create(params[:invitation])
    respond_with(:admin, @invitation)
  end

  def edit
    @user = User.get!(params[:id])
    respond_with(:admin, @user)
  end

  def update
    @user = User.get!(params[:id])
    @user.update(params[:user])
    respond_with(:admin, @user)
  end

  def lock
    @user = User.get!(params[:id])
    @user.lock!
    respond_with(:admin, @user)
  end

  def unlock
    @user = User.get!(params[:id])
    @user.unlock!
    respond_with(:admin, @user)
  end

  def confirm
    @user = User.get!(params[:id])
    @user.update(:confirmed_at => Time.now)
    respond_with(:admin, @user)
  end
  
  def validate_can_invite
    @subscription_scope = SubscriptionScope.first(:name => "User")

    if @subscription_scope.nil?
      flash[:notice] = "Please create a SubscriptionScope with the name 'User'"
      redirect_to admin_subscription_scopes_path and return
    end
      
    if @subscription_scope.subscription_plans.count <= 0
      flash[:notice] = "Please create a Subscription Plan for the User Scope"
      redirect_to admin_subscription_plans_path and return
    end
  
    @subscription_plans = @subscription_scope.subscription_plans
  end

end

