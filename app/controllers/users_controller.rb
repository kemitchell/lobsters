class UsersController < ApplicationController
  before_action :load_showing_user, :only => [:show, :standing]
  before_action :require_logged_in_moderator,
                :only => [:enable_invitation, :disable_invitation, :ban, :unban]
  before_action :flag_warning, only: [:show]
  before_action :require_logged_in_user, only: [:standing]
  before_action :only_user_or_moderator, only: [:standing]

  def show
    @title = "User #{@showing_user.username}"

    if @user.try(:is_moderator?)
      @mod_note = ModNote.new(user: @showing_user)
      @mod_note.note = params[:note]
    end

    respond_to do |format|
      format.html { render :action => "show" }
      format.json { render :json => @showing_user }
    end
  end

  def tree
    @title = "Users"
    newest_user = User.last.id

    # pulling 10k+ users is significant enough memory pressure this is worthwhile
    attrs = %w{banned_at created_at deleted_at id invited_by_user_id is_admin is_moderator karma
      username}

    if params[:by].to_s == "karma"
      content = Rails.cache.fetch("users_by_karma_#{newest_user}", :expires_in => (60 * 60 * 24)) {
        @users = User.select(*attrs).order("karma DESC, id ASC").to_a
        @user_count = @users.length
        @title << " By Karma"
        render_to_string :action => "list", :layout => nil
      }
      render :html => content.html_safe, :layout => "application"
    elsif params[:moderators]
      @users = User.select(*attrs).where("is_admin = ? OR is_moderator = ?", true, true)
        .order("id ASC").to_a
      @user_count = @users.length
      @title = "Moderators and Administrators"
      render :action => "list"
    else
      content = Rails.cache.fetch("users_tree_#{newest_user}", :expires_in => (60 * 60 * 24)) {
        users = User.select(*attrs).order("id DESC").to_a
        @user_count = users.length
        @users_by_parent = users.group_by(&:invited_by_user_id)
        @newest = User.select(*attrs).order("id DESC").limit(10)
        render_to_string :action => "tree", :layout => nil
      }
      render :html => content.html_safe, :layout => "application"
    end
  end

  def invite
    @title = "Pass Along an Invitation"
  end

  def disable_invitation
    target = User.where(:username => params[:username]).first
    if !target
      flash[:error] = "Invalid user."
      redirect_to "/"
    else
      target.disable_invite_by_user_for_reason!(@user, params[:reason])

      flash[:success] = "User has had invite capability disabled."
      redirect_to user_path(:user => target.username)
    end
  end

  def enable_invitation
    target = User.where(:username => params[:username]).first
    if !target
      flash[:error] = "Invalid user."
      redirect_to "/"
    else
      target.enable_invite_by_user!(@user)

      flash[:success] = "User has had invite capability enabled."
      redirect_to user_path(:user => target.username)
    end
  end

  def ban
    buser = User.where(:username => params[:username]).first
    if !buser
      flash[:error] = "Invalid user."
      return redirect_to "/"
    end

    if !params[:reason].present?
      flash[:error] = "You must give a reason for the ban."
      return redirect_to user_path(:user => buser.username)
    end

    buser.ban_by_user_for_reason!(@user, params[:reason])

    flash[:success] = "User has been banned."
    return redirect_to user_path(:user => buser.username)
  end

  def unban
    buser = User.where(:username => params[:username]).first
    if !buser
      flash[:error] = "Invalid user."
      return redirect_to "/"
    end

    buser.unban_by_user!(@user)

    flash[:success] = "User has been unbanned."
    return redirect_to user_path(:user => buser.username)
  end

  def standing
    flag_warning
    int = @flag_warning_int

    fc = FlaggedCommenters.new(int[:param], 1.day)
    @fc_flagged = fc.commenters.map {|_, c| c[:n_flags] }.sort
    @flagged_user_stats = fc.check_list_for(@showing_user)

    rows = ActiveRecord::Base.connection.exec_query("
      select
        n_flags, count(*) as n_users
      from (
        select
          comments.user_id, sum(flags) as n_flags
        from
          comments
        where
          comments.created_at >= now() - interval #{int[:dur]} #{int[:intv]}
        group by comments.user_id) count_by_user
      group by 1
      order by 1 asc;
    ").rows
    users = Array.new(@fc_flagged.last.to_i + 1, 0)
    rows.each {|r| users[r.first] = r.last }
    @lookup = rows.to_h

    @flagged_comments = @showing_user.comments
      .where("
        comments.flags > 0 and
        comments.created_at >= now() - interval #{int[:dur]} #{int[:intv]}")
      .order("id DESC")
      .includes(:user, :hat, :story => :user)
      .joins(:story)
  end

private

  def load_showing_user
    # case-insensitive search by username
    @showing_user = User.find_by(username: params[:username])

    if @showing_user.nil?
      render action: :not_found, status: 404
      return false
    end

    # now a case-sensitive check
    if params[:username] != @showing_user.username
      redirect_to username: @showing_user.username
      return false
    end
  end

  def only_user_or_moderator
    if params[:username] == @user.username || @user.is_moderator?
      true
    else
      redirect_to(user_path(params[:username]))
    end
  end
end
