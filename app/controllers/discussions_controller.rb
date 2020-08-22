class DiscussionsController < ApplicationController
  include DiscussionHelper
  include ScriptAndVersions

  FILTER_RESULT = Struct.new(:category, :by_user, :related_to_me, :read_status, :result)

  before_action :authenticate_user!, only: [:new, :create, :subscribe, :unsubscribe]
  before_action :moderators_only, only: :destroy
  before_action :greasy_only, only: :new

  layout 'discussions', only: :index
  layout 'application', only: [:new, :create]

  def index
    @discussions = Discussion
                   .visible
                   .includes(:poster, :script, :discussion_category)
                   .order(stat_last_reply_date: :desc)
    case script_subset
    when :sleazyfork
      @discussions = @discussions.where(scripts: { sensitive: true })
    when :greasyfork
      @discussions = @discussions.where(scripts: { sensitive: [nil, false] })
    when :all
      # No restrictions
    else
      raise "Unknown subset #{script_subset}"
    end

    @filter_result = apply_filters(@discussions)

    @discussions = @filter_result.result
    @discussions = @discussions.paginate(page: params[:page], per_page: 25)

    @discussion_ids_read = DiscussionRead.read_ids_for(@discussions, current_user) if current_user
  end

  def show
    # Allow mods and the poster to see discussions under review.
    @discussion = discussion_scope(permissive: true).find(params[:id])

    if @discussion.script
      return if handle_publicly_deleted(@discussion.script)

      case script_subset
      when :sleazyfork
        unless @discussion.script.sensitive?
          render_404
          return
        end
      when :greasyfork
        if @discussion.script.sensitive?
          render_404
          return
        end
      when :all
        # No restrictions
      else
        raise "Unknown subset #{script_subset}"
      end
    end

    respond_to do |format|
      format.html do
        @comment = @discussion.comments.build(text_markup: current_user&.preferred_markup)
        @subscribe = current_user&.subscribe_on_comment || current_user&.subscribed_to?(@discussion)

        record_view(@discussion) if current_user

        render layout: @script ? 'scripts' : 'application'
      end
      format.all do
        head :unprocessable_entity
      end
    end
  end

  def new
    @discussion = Discussion.new(poster: current_user)
    @discussion.comments.build(poster: current_user, text_markup: current_user&.preferred_markup)
    @subscribe = current_user.subscribe_on_discussion
  end

  def create
    if current_user.email&.ends_with?('163.com') && current_user.created_at > 7.days.ago && current_user.discussions.where(created_at: 1.hour.ago..).any?
      render plain: 'Please try again later.'
      return
    end

    @discussion = discussion_scope.new(discussion_params)
    @discussion.poster = @discussion.comments.first.poster = current_user
    if @script
      @discussion.script = @script
      @discussion.discussion_category = DiscussionCategory.script_discussions
    end
    @discussion.comments.first.first_comment = true
    @subscribe = params[:subscribe] == '1'

    recaptcha_ok = current_user.needs_to_recaptcha? ? verify_recaptcha : true
    unless recaptcha_ok && @discussion.valid?
      render :new
      return
    end

    @discussion.save!
    @discussion.comments.first.send_notifications!

    DiscussionSubscription.find_or_create_by!(user: current_user, discussion: @discussion) if @subscribe

    AkismetCheckingJob.perform_later(@discussion, request.ip, request.user_agent, request.referer)

    redirect_to @discussion.path
  end

  def destroy
    discussion = discussion_scope.find(params[:id])
    discussion.soft_destroy!
    if discussion.script
      redirect_to script_path(discussion.script)
    else
      redirect_to discussions_path
    end
  end

  def subscribe
    discussion = discussion_scope.find(params[:id])
    DiscussionSubscription.find_or_create_by!(user: current_user, discussion: discussion)
    respond_to do |format|
      format.js { head 200 }
      format.all { redirect_to discussion.path }
    end
  end

  def unsubscribe
    discussion = discussion_scope.find(params[:id])
    DiscussionSubscription.find_by(user: current_user, discussion: discussion)&.destroy
    respond_to do |format|
      format.js { head 200 }
      format.all { redirect_to discussion.path }
    end
  end

  def old_redirect
    redirect_to Discussion.find_by!(migrated_from: params[:id]).url, status: 301
  end

  def mark_all_read
    filter_result = apply_filters(Discussion.all)

    if filter_result.category || filter_result.related_to_me || filter_result.by_user
      now = Time.now
      ids = filter_result.result.pluck(:id)
      DiscussionRead.upsert_all(ids.map { |discussion_id| { discussion_id: discussion_id, user_id: current_user.id, read_at: now } }) if ids.any?
    else
      current_user.update!(discussions_read_since: Time.now)
    end

    redirect_back(fallback_location: discussions_path)
  end

  private

  def discussion_scope(permissive: false)
    scope = if params[:script_id]
              @script = Script.find(params[:script_id])
              @script.discussions
            else
              Discussion
            end
    if permissive && current_user
      scope.permissive_visible(current_user)
    else
      scope.visible
    end
  end

  def discussion_params
    params
      .require(:discussion)
      .permit(:rating, :title, :discussion_category_id, comments_attributes: [:text, :text_markup, { attachments: [] }])
  end

  def record_view(discussion)
    DiscussionRead.upsert({ user_id: current_user.id, discussion_id: discussion.id, read_at: Time.now })
  end

  def apply_filters(discussions)
    if params[:category]
      if params[:category] == 'no-scripts'
        category = params[:category]
        discussions = discussions.where(discussion_category: DiscussionCategory.non_script)
      else
        category = DiscussionCategory.find_by(category_key: params[:category])
        discussions = discussions.where(discussion_category: category) if category
      end
    end

    if current_user
      related_to_me = params[:me]
      case related_to_me
      when 'started'
        discussions = discussions.where(poster: current_user)
      when 'comment'
        discussions = discussions.with_comment_by(current_user)
      when 'script'
        discussions = discussions.where(script_id: current_user.script_ids)
      when 'subscribed'
        discussions = discussions.where(id: current_user.discussion_subscriptions.pluck(:discussion_id))
      else
        related_to_me = nil
      end
    end

    if params[:user].to_i > 0
      by_user = User.find_by(id: params[:user].to_i)
      discussions = discussions.with_comment_by(by_user) if by_user
    end

    # This needs to be the last.
    if current_user
      read_status = params[:read]
      case read_status
      when 'read'
        discussions = discussions.where(id: DiscussionRead.read_ids_for(discussions, current_user))
      when 'unread'
        discussions = discussions.where.not(id: DiscussionRead.read_ids_for(discussions, current_user))
      else
        read_status = nil
      end
    end

    FILTER_RESULT.new(category, by_user, related_to_me, read_status, discussions)
  end
end
