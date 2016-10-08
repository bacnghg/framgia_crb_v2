class Api::EventsController < ApplicationController
  include CreateNewObject
  include TimeOverlapForUpdate
  include Authenticable unless :is_desktop_client?
  serialization_scope :current_user

  respond_to :json
  before_action :authenticate_with_token! unless :is_desktop_client?
  before_action :load_event, except: [:index, :new, :edit]
  before_action only: [:edit, :update, :destroy] do
    validate_permission_change_of_calendar @event.calendar
  end
  before_action only: :show do
    validate_permission_see_detail_of_calendar @event.calendar
  end

  def index
    if params[:page].present? || params[:calendar_id]
      @data = current_user.events.upcoming_event(params[:calendar_id])
        .page(params[:page]).per Settings.users.upcoming_event
      respond_to do |format|
        format.html {
          render partial: "users/event", locals: {events: @data, user: current_user}
        }
      end
    else
      @events = Event.in_calendars params[:calendars]
      serializer = EventSerializer
      generate_desktop_events if is_desktop_client?
      render json: @events, each_serializer: FullCalendar::EventSerializer,
        root: :events, adapter: :json,
        meta: t("api.request_success"), meta_key: :message,
        status: :ok
    end
  end

  def create
    @event = current_user.events.build event_params
    place = Place.find_by name: params[:name_place]

    if place.present?
      @event.place_id = place.id
    end

    event_overlap = EventOverlap.new @event
    if event_overlap.overlap?
      @time_overlap = event_overlap.overlap_time
      render json: {message: I18n.t("api.event_overlap")}
    else
      if @event.save
        render json: @event, meta: t("api.create_event_success"),
          meta_key: message, status: :ok
      else
        render json: {errors: I18n.t("api.create_event_failed")}, status: 422
      end
    end
  end

  def update
    params[:event] = params[:event].merge({
      exception_time: event_params[:start_date],
      start_repeat: event_params[:start_date],
      end_repeat: event_params[:end_repeat].blank? ? @event.end_repeat : (event_params[:end_repeat])
    })

    argv = {
      is_drop: params[:is_drop],
      start_time_before_drag: params[:start_time_before_drag],
      finish_time_before_drag: params[:finish_time_before_drag]
    }

    event = Event.new handle_event_params
    event.parent_id = @event.event_parent.nil? ? @event.id : @event.parent_id
    event.calendar_id = @event.calendar_id

    if overlap_when_update? event
      render json: {
        text: t("events.flashs.not_updated_because_overlap")
      }, status: :bad_request
    else
      exception_service = EventExceptionService.new(handle_event, params, argv)
      exception_service.update_event_exception

      render json: {
        message: t("events.flashs.updated"),
        event: exception_service.new_event.as_json
      }, status: :ok
    end
  end

  def show
    locals = {
      event_id: params[:id],
      start_date: params[:start],
      finish_date: params[:end]
    }.to_json

    @event.start_date = params[:start]
    @event.finish_date = params[:end]

    respond_to do |format|
      format.html {
        render partial: "events/popup",
          locals: {
            user: current_user,
            event: @event,
            title: params[:title],
            place_id: params[:place_id],
            name_place: params[:name_place],
            start_date: params[:start],
            finish_date: params[:end],
            fdata: Base64.urlsafe_encode64(locals)
          }
      }
      format.json {render json: @event,
        meta: t("api.show_detail_event_suceess"), meta_key: :message}
    end
  end

  def destroy
    @event = Event.find_by id: params[:id]
    if delete_all_event?
      event = @event
      if @event.exception_type.present?
        event = @event.parent? ? @event : @event.event_parent
      end
      destroy_event event
    else
      destroy_event_repeat
      render json: {message: t("events.flashs.deleted")}
    end
  end

  private
  def event_params
    params.require(:event).permit Event::ATTRIBUTES_PARAMS
  end

  def handle_event_params
    params.require(:event).permit Event::ATTRIBUTES_PARAMS[1..-2]
  end

  def exception_params
    params.permit :title, :all_day, :start_repeat, :end_repeat,
      :start_date, :finish_date, :exception_type, :exception_time, :parent_id,
      :place_id, :name_place
  end

  def load_event
    @event = Event.find_by id: params[:id]
  end

  def destroy_event event
    event_temp = event.dup
    event_temp.attendees = event.attendees
    if event.destroy
      render json: {message: t("events.flashs.deleted")}, status: :ok
    else
      render json: {message: t("events.flashs.not_deleted")}
    end
  end

  def destroy_event_repeat
    exception_type = params[:exception_type]
    exception_time = params[:exception_time]
    start_date_before_delete = params[:start_date_before_delete]
    finish_date_before_delete = params[:finish_date_before_delete]
    if unpersisted_event?
      parent = @event.parent_id.present? ? @event.event_parent : @event
      dup_event = parent.dup
      dup_event.exception_type = exception_type
      dup_event.exception_time = exception_time
      dup_event.parent_id = parent.id
      parent.attendees.each do |attendee|
        dup_event.attendees.new(user_id: attendee.user_id,
          event_id: dup_event.id)
      end
      if @event.all_day?
        dup_event.start_date = exception_time.to_datetime.beginning_of_day
        dup_event.finish_date = exception_time.to_datetime.end_of_day
      else
        dup_event.start_date = start_date_before_delete
        dup_event.finish_date = finish_date_before_delete
      end
      if exception_type == "delete_all_follow"
        event_exception_pre_nearest(parent, exception_time).update(end_repeat: (exception_time.to_date - 1.day))
      end
      return dup_event.save
    elsif @event.edit_all_follow? && exception_type == "delete_only"
      @event.update(old_exception_type: Event.exception_types[:edit_all_follow])
    elsif @event.parent? && exception_type == "delete_only"
      @event.update(old_exception_type: Event.exception_types[:edit_all_follow])
    end

    @event.update_attributes exception_type: exception_type, exception_time: exception_time
  end


  def unpersisted_event?
    params[:persisted].to_i == 0
  end

  def handle_event
    return @event if @event.parent_id.blank?
    params[:persisted].to_i == 0 ? @event.event_parent : @event
  end

  def delete_all_event?
    params[:exception_type] ==  "delete_all"
  end

  def event_exception_pre_nearest parent, exception_time
    events = parent.event_exceptions
      .follow_pre_nearest(exception_time).order(start_date: :desc)
    events.size > 0 ? events.first : parent
  end

  def generate_desktop_events
    calendar_service = CalendarService.new(@events, params[:start_time_view],
          params[:end_time_view])
    calendar_service.user = current_user
    @events = calendar_service.repeat_data
  end
end
