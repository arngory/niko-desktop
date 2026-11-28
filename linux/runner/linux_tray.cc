#include "linux_tray.h"

#include <unistd.h>

#include <cstring>

namespace {

constexpr char kSniPath[] = "/StatusNotifierItem";
constexpr char kMenuPath[] = "/MenuBar";
constexpr char kSniInterface[] = "org.kde.StatusNotifierItem";
constexpr char kMenuInterface[] = "com.canonical.dbusmenu";
constexpr char kWatcherBusName[] = "org.kde.StatusNotifierWatcher";
constexpr char kWatcherPath[] = "/StatusNotifierWatcher";
constexpr char kWatcherInterface[] = "org.kde.StatusNotifierWatcher";

constexpr gint32 kMenuRoot = 0;
constexpr gint32 kMenuStatus = 1;
constexpr gint32 kMenuSep1 = 2;
constexpr gint32 kMenuToggle = 3;
constexpr gint32 kMenuMode = 7;
constexpr gint32 kMenuOpen = 4;
constexpr gint32 kMenuSep2 = 5;
constexpr gint32 kMenuQuit = 6;

const gchar kSniIntrospectionXml[] = R"xml(
<node>
  <interface name='org.kde.StatusNotifierItem'>
    <property name='Category' type='s' access='read'/>
    <property name='Id' type='s' access='read'/>
    <property name='Title' type='s' access='read'/>
    <property name='Status' type='s' access='read'/>
    <property name='WindowId' type='u' access='read'/>
    <property name='IconName' type='s' access='read'/>
    <property name='OverlayIconName' type='s' access='read'/>
    <property name='AttentionIconName' type='s' access='read'/>
    <property name='AttentionMovieName' type='s' access='read'/>
    <property name='ToolTip' type='(sa(iiay)ss)' access='read'/>
    <property name='ItemIsMenu' type='b' access='read'/>
    <property name='Menu' type='o' access='read'/>
    <method name='ContextMenu'>
      <arg name='x' type='i' direction='in'/>
      <arg name='y' type='i' direction='in'/>
    </method>
    <method name='Activate'>
      <arg name='x' type='i' direction='in'/>
      <arg name='y' type='i' direction='in'/>
    </method>
    <method name='SecondaryActivate'>
      <arg name='x' type='i' direction='in'/>
      <arg name='y' type='i' direction='in'/>
    </method>
    <method name='Scroll'>
      <arg name='delta' type='i' direction='in'/>
      <arg name='orientation' type='s' direction='in'/>
    </method>
    <signal name='NewTitle'/>
    <signal name='NewIcon'/>
    <signal name='NewAttentionIcon'/>
    <signal name='NewOverlayIcon'/>
    <signal name='NewToolTip'/>
    <signal name='NewStatus'>
      <arg name='status' type='s'/>
    </signal>
  </interface>
</node>
)xml";

const gchar kMenuIntrospectionXml[] = R"xml(
<node>
  <interface name='com.canonical.dbusmenu'>
    <property name='Version' type='u' access='read'/>
    <property name='TextDirection' type='s' access='read'/>
    <property name='Status' type='s' access='read'/>
    <property name='IconThemePath' type='as' access='read'/>
    <method name='GetLayout'>
      <arg name='parentId' type='i' direction='in'/>
      <arg name='recursionDepth' type='i' direction='in'/>
      <arg name='propertyNames' type='as' direction='in'/>
      <arg name='revision' type='u' direction='out'/>
      <arg name='layout' type='(ia{sv}av)' direction='out'/>
    </method>
    <method name='GetGroupProperties'>
      <arg name='ids' type='ai' direction='in'/>
      <arg name='propertyNames' type='as' direction='in'/>
      <arg name='properties' type='a(ia{sv})' direction='out'/>
    </method>
    <method name='GetProperty'>
      <arg name='id' type='i' direction='in'/>
      <arg name='name' type='s' direction='in'/>
      <arg name='value' type='v' direction='out'/>
    </method>
    <method name='Event'>
      <arg name='id' type='i' direction='in'/>
      <arg name='eventId' type='s' direction='in'/>
      <arg name='data' type='v' direction='in'/>
      <arg name='timestamp' type='u' direction='in'/>
    </method>
    <method name='EventGroup'>
      <arg name='events' type='a(isvu)' direction='in'/>
      <arg name='idErrors' type='ai' direction='out'/>
    </method>
    <method name='AboutToShow'>
      <arg name='id' type='i' direction='in'/>
      <arg name='needUpdate' type='b' direction='out'/>
    </method>
    <method name='AboutToShowGroup'>
      <arg name='ids' type='ai' direction='in'/>
      <arg name='updatesNeeded' type='ai' direction='out'/>
      <arg name='idErrors' type='ai' direction='out'/>
    </method>
    <signal name='ItemsPropertiesUpdated'>
      <arg name='updatedProps' type='a(ia{sv})'/>
      <arg name='removedProps' type='a(ias)'/>
    </signal>
    <signal name='LayoutUpdated'>
      <arg name='revision' type='u'/>
      <arg name='parent' type='i'/>
    </signal>
    <signal name='ItemActivationRequested'>
      <arg name='id' type='i'/>
      <arg name='timestamp' type='u'/>
    </signal>
  </interface>
</node>
)xml";

}  // namespace

LinuxTray::LinuxTray(ActionCallback on_action)
    : on_action_(std::move(on_action)),
      cancellable_(g_cancellable_new()),
      bus_name_("org.kde.StatusNotifierItem-" + std::to_string(getpid()) + "-1") {}

LinuxTray::~LinuxTray() {
  if (cancellable_ != nullptr) {
    g_cancellable_cancel(cancellable_);
    g_clear_object(&cancellable_);
  }
  if (watcher_id_ != 0) {
    g_bus_unwatch_name(watcher_id_);
    watcher_id_ = 0;
  }
  if (own_name_id_ != 0) {
    g_bus_unown_name(own_name_id_);
    own_name_id_ = 0;
  }
  if (bus_ != nullptr) {
    if (sni_reg_id_ != 0) {
      g_dbus_connection_unregister_object(bus_, sni_reg_id_);
      sni_reg_id_ = 0;
    }
    if (menu_reg_id_ != 0) {
      g_dbus_connection_unregister_object(bus_, menu_reg_id_);
      menu_reg_id_ = 0;
    }
    g_clear_object(&bus_);
  }
  if (sni_node_info_ != nullptr) {
    g_dbus_node_info_unref(sni_node_info_);
    sni_node_info_ = nullptr;
  }
  if (menu_node_info_ != nullptr) {
    g_dbus_node_info_unref(menu_node_info_);
    menu_node_info_ = nullptr;
  }
}

void LinuxTray::Update(bool connected,
                       const std::string& status_label,
                       const std::string& profile_name,
                       const std::string& toggle_label,
                       const std::string& mode_label,
                       const std::string& open_label,
                       const std::string& quit_label) {
  std::string next_header = status_label.empty() ? "Niko" : status_label;
  if (!profile_name.empty()) {
    next_header += " · ";
    next_header += profile_name;
  }
  const bool icon_or_title_changed =
      (connected_ != connected) || (header_label_ != next_header);
  const bool menu_changed = icon_or_title_changed ||
                            (toggle_label_ != toggle_label) ||
                            (mode_label_ != mode_label) ||
                            (open_label_ != open_label) ||
                            (quit_label_ != quit_label);

  connected_ = connected;
  header_label_ = std::move(next_header);
  toggle_label_ = toggle_label;
  mode_label_ = mode_label;
  open_label_ = open_label;
  quit_label_ = quit_label;

  EnsureInitialized();

  if (exported_) {
    if (icon_or_title_changed) {
      EmitIconAndTitleChanged();
    }
    if (menu_changed) {
      ++menu_revision_;
      EmitLayoutUpdated();
    }
  }
}

void LinuxTray::EnsureInitialized() {
  if (init_started_) return;
  init_started_ = true;
  g_bus_get(G_BUS_TYPE_SESSION, cancellable_, OnBusReady, this);
}

void LinuxTray::OnBusReady(GObject* /*source*/, GAsyncResult* res, gpointer user_data) {
  g_autoptr(GError) error = nullptr;
  GDBusConnection* bus = g_bus_get_finish(res, &error);
  if (bus == nullptr) {
    // Expected when running headless or cancelled during shutdown.
    return;
  }

  auto* self = static_cast<LinuxTray*>(user_data);
  self->bus_ = bus;

  self->sni_node_info_ = g_dbus_node_info_new_for_xml(kSniIntrospectionXml, &error);
  if (self->sni_node_info_ == nullptr) {
    g_warning("niko tray: failed to parse SNI XML: %s", error ? error->message : "unknown");
    return;
  }
  self->menu_node_info_ = g_dbus_node_info_new_for_xml(kMenuIntrospectionXml, &error);
  if (self->menu_node_info_ == nullptr) {
    g_warning("niko tray: failed to parse DBusMenu XML: %s", error ? error->message : "unknown");
    return;
  }

  static const GDBusInterfaceVTable sni_vtable = {
      SniMethodCall,
      SniGetProperty,
      nullptr,
      {nullptr},
  };
  static const GDBusInterfaceVTable menu_vtable = {
      MenuMethodCall,
      MenuGetProperty,
      nullptr,
      {nullptr},
  };

  self->sni_reg_id_ = g_dbus_connection_register_object(
      self->bus_, kSniPath, self->sni_node_info_->interfaces[0], &sni_vtable, self, nullptr,
      &error);
  if (self->sni_reg_id_ == 0) {
    g_warning("niko tray: failed to register SNI object: %s", error ? error->message : "unknown");
    return;
  }

  self->menu_reg_id_ = g_dbus_connection_register_object(
      self->bus_, kMenuPath, self->menu_node_info_->interfaces[0], &menu_vtable, self, nullptr,
      &error);
  if (self->menu_reg_id_ == 0) {
    g_warning("niko tray: failed to register DBusMenu object: %s",
              error ? error->message : "unknown");
    return;
  }

  self->exported_ = true;

  self->own_name_id_ = g_bus_own_name_on_connection(
      self->bus_, self->bus_name_.c_str(), G_BUS_NAME_OWNER_FLAGS_NONE, nullptr, nullptr, nullptr,
      nullptr);

  self->watcher_id_ = g_bus_watch_name_on_connection(
      self->bus_, kWatcherBusName, G_BUS_NAME_WATCHER_FLAGS_NONE, OnWatcherAppeared,
      OnWatcherVanished, self, nullptr);
}

void LinuxTray::OnWatcherAppeared(GDBusConnection* /*conn*/,
                                  const gchar* /*name*/,
                                  const gchar* /*name_owner*/,
                                  gpointer user_data) {
  auto* self = static_cast<LinuxTray*>(user_data);
  self->watcher_present_ = true;
  self->RegisterWithWatcher();
}

void LinuxTray::OnWatcherVanished(GDBusConnection* /*conn*/,
                                  const gchar* /*name*/,
                                  gpointer user_data) {
  auto* self = static_cast<LinuxTray*>(user_data);
  self->watcher_present_ = false;
}

void LinuxTray::RegisterWithWatcher() {
  if (bus_ == nullptr || !exported_) return;
  g_dbus_connection_call(bus_, kWatcherBusName, kWatcherPath, kWatcherInterface,
                         "RegisterStatusNotifierItem",
                         g_variant_new("(s)", bus_name_.c_str()), nullptr,
                         G_DBUS_CALL_FLAGS_NONE, -1, cancellable_, nullptr, nullptr);
}

void LinuxTray::EmitIconAndTitleChanged() {
  if (bus_ == nullptr || !exported_) return;
  g_dbus_connection_emit_signal(bus_, nullptr, kSniPath, kSniInterface, "NewIcon", nullptr,
                                nullptr);
  g_dbus_connection_emit_signal(bus_, nullptr, kSniPath, kSniInterface, "NewTitle", nullptr,
                                nullptr);
  g_dbus_connection_emit_signal(bus_, nullptr, kSniPath, kSniInterface, "NewToolTip", nullptr,
                                nullptr);
}

void LinuxTray::EmitLayoutUpdated() {
  if (bus_ == nullptr || !exported_) return;
  g_dbus_connection_emit_signal(bus_, nullptr, kMenuPath, kMenuInterface, "LayoutUpdated",
                                g_variant_new("(ui)", menu_revision_, kMenuRoot), nullptr);
}

GVariant* LinuxTray::BuildMenuItemProps(gint32 id) const {
  GVariantBuilder props;
  g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
  switch (id) {
    case kMenuRoot:
      g_variant_builder_add(&props, "{sv}", "children-display", g_variant_new_string("submenu"));
      break;
    case kMenuStatus:
      g_variant_builder_add(&props, "{sv}", "label", g_variant_new_string(header_label_.c_str()));
      g_variant_builder_add(&props, "{sv}", "enabled", g_variant_new_boolean(FALSE));
      g_variant_builder_add(&props, "{sv}", "visible", g_variant_new_boolean(TRUE));
      break;
    case kMenuSep1:
    case kMenuSep2:
      g_variant_builder_add(&props, "{sv}", "type", g_variant_new_string("separator"));
      g_variant_builder_add(&props, "{sv}", "visible", g_variant_new_boolean(TRUE));
      break;
    case kMenuToggle:
      g_variant_builder_add(&props, "{sv}", "label", g_variant_new_string(toggle_label_.c_str()));
      g_variant_builder_add(&props, "{sv}", "enabled", g_variant_new_boolean(TRUE));
      g_variant_builder_add(&props, "{sv}", "visible", g_variant_new_boolean(TRUE));
      break;
    case kMenuMode:
      g_variant_builder_add(&props, "{sv}", "label", g_variant_new_string(mode_label_.c_str()));
      g_variant_builder_add(&props, "{sv}", "enabled", g_variant_new_boolean(TRUE));
      g_variant_builder_add(&props, "{sv}", "visible", g_variant_new_boolean(!mode_label_.empty()));
      break;
    case kMenuOpen:
      g_variant_builder_add(&props, "{sv}", "label", g_variant_new_string(open_label_.c_str()));
      g_variant_builder_add(&props, "{sv}", "enabled", g_variant_new_boolean(TRUE));
      g_variant_builder_add(&props, "{sv}", "visible", g_variant_new_boolean(TRUE));
      break;
    case kMenuQuit:
      g_variant_builder_add(&props, "{sv}", "label", g_variant_new_string(quit_label_.c_str()));
      g_variant_builder_add(&props, "{sv}", "enabled", g_variant_new_boolean(TRUE));
      g_variant_builder_add(&props, "{sv}", "visible", g_variant_new_boolean(TRUE));
      break;
    default:
      break;
  }
  return g_variant_builder_end(&props);
}

GVariant* LinuxTray::BuildMenuLayoutNode(gint32 id, gint32 depth) const {
  GVariant* props = BuildMenuItemProps(id);
  GVariantBuilder children;
  g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
  if (id == kMenuRoot && (depth < 0 || depth > 0)) {
    const gint32 next_depth = depth < 0 ? -1 : depth - 1;
    const gint32 child_ids[] = {kMenuStatus, kMenuSep1, kMenuToggle, kMenuMode,
                                kMenuOpen,   kMenuSep2, kMenuQuit};
    for (gint32 child_id : child_ids) {
      g_variant_builder_add(&children, "v", BuildMenuLayoutNode(child_id, next_depth));
    }
  }
  return g_variant_new("(i@a{sv}@av)", id, props, g_variant_builder_end(&children));
}

void LinuxTray::SniMethodCall(GDBusConnection* /*conn*/,
                              const gchar* /*sender*/,
                              const gchar* /*object_path*/,
                              const gchar* /*interface_name*/,
                              const gchar* method_name,
                              GVariant* /*parameters*/,
                              GDBusMethodInvocation* invocation,
                              gpointer user_data) {
  auto* self = static_cast<LinuxTray*>(user_data);
  if (g_strcmp0(method_name, "Activate") == 0) {
    if (self->on_action_) self->on_action_("show");
    g_dbus_method_invocation_return_value(invocation, nullptr);
  } else if (g_strcmp0(method_name, "SecondaryActivate") == 0) {
    if (self->on_action_) self->on_action_("toggle");
    g_dbus_method_invocation_return_value(invocation, nullptr);
  } else if (g_strcmp0(method_name, "ContextMenu") == 0 ||
             g_strcmp0(method_name, "Scroll") == 0) {
    g_dbus_method_invocation_return_value(invocation, nullptr);
  } else {
    g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
                                          "Unknown SNI method: %s", method_name);
  }
}

GVariant* LinuxTray::SniGetProperty(GDBusConnection* /*conn*/,
                                    const gchar* /*sender*/,
                                    const gchar* /*object_path*/,
                                    const gchar* /*interface_name*/,
                                    const gchar* property_name,
                                    GError** error,
                                    gpointer user_data) {
  auto* self = static_cast<LinuxTray*>(user_data);
  const char* icon = self->connected_ ? "network-vpn" : "network-offline";
  if (g_strcmp0(property_name, "Category") == 0) {
    return g_variant_new_string("ApplicationStatus");
  }
  if (g_strcmp0(property_name, "Id") == 0) {
    return g_variant_new_string("niko-desktop");
  }
  if (g_strcmp0(property_name, "Title") == 0) {
    return g_variant_new_string(self->header_label_.c_str());
  }
  if (g_strcmp0(property_name, "Status") == 0) {
    return g_variant_new_string("Active");
  }
  if (g_strcmp0(property_name, "WindowId") == 0) {
    return g_variant_new_uint32(0);
  }
  if (g_strcmp0(property_name, "IconName") == 0) {
    return g_variant_new_string(icon);
  }
  if (g_strcmp0(property_name, "OverlayIconName") == 0 ||
      g_strcmp0(property_name, "AttentionIconName") == 0 ||
      g_strcmp0(property_name, "AttentionMovieName") == 0) {
    return g_variant_new_string("");
  }
  if (g_strcmp0(property_name, "ToolTip") == 0) {
    GVariantBuilder pixmaps;
    g_variant_builder_init(&pixmaps, G_VARIANT_TYPE("a(iiay)"));
    return g_variant_new("(s@a(iiay)ss)", icon, g_variant_builder_end(&pixmaps), "Niko",
                         self->header_label_.c_str());
  }
  if (g_strcmp0(property_name, "ItemIsMenu") == 0) {
    return g_variant_new_boolean(FALSE);
  }
  if (g_strcmp0(property_name, "Menu") == 0) {
    return g_variant_new_object_path(kMenuPath);
  }
  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY, "Unknown SNI property: %s",
              property_name);
  return nullptr;
}

void LinuxTray::MenuMethodCall(GDBusConnection* /*conn*/,
                               const gchar* /*sender*/,
                               const gchar* /*object_path*/,
                               const gchar* /*interface_name*/,
                               const gchar* method_name,
                               GVariant* parameters,
                               GDBusMethodInvocation* invocation,
                               gpointer user_data) {
  auto* self = static_cast<LinuxTray*>(user_data);

  if (g_strcmp0(method_name, "GetLayout") == 0) {
    gint32 parent_id = 0;
    gint32 depth = -1;
    g_variant_get(parameters, "(ii@as)", &parent_id, &depth, nullptr);
    GVariant* node = self->BuildMenuLayoutNode(parent_id, depth);
    g_dbus_method_invocation_return_value(invocation,
                                          g_variant_new("(u@(ia{sv}av))", self->menu_revision_, node));
    return;
  }

  if (g_strcmp0(method_name, "GetGroupProperties") == 0) {
    g_autoptr(GVariantIter) ids = nullptr;
    g_variant_get(parameters, "(ai@as)", &ids, nullptr);
    GVariantBuilder out;
    g_variant_builder_init(&out, G_VARIANT_TYPE("a(ia{sv})"));
    gint32 id = 0;
    while (g_variant_iter_loop(ids, "i", &id)) {
      g_variant_builder_add(&out, "(i@a{sv})", id, self->BuildMenuItemProps(id));
    }
    g_dbus_method_invocation_return_value(invocation,
                                          g_variant_new("(@a(ia{sv}))", g_variant_builder_end(&out)));
    return;
  }

  if (g_strcmp0(method_name, "GetProperty") == 0) {
    gint32 id = 0;
    const gchar* name = nullptr;
    g_variant_get(parameters, "(i&s)", &id, &name);
    g_autoptr(GVariant) props = g_variant_ref_sink(self->BuildMenuItemProps(id));
    g_autoptr(GVariant) val = g_variant_lookup_value(props, name, nullptr);
    if (val == nullptr) {
      val = g_variant_ref_sink(g_variant_new_string(""));
    }
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(v)", val));
    return;
  }

  auto dispatch_click = [self](gint32 id) {
    if (!self->on_action_) return;
    if (id == kMenuToggle) self->on_action_("toggle");
    if (id == kMenuMode) self->on_action_("toggleMode");
    if (id == kMenuOpen) self->on_action_("show");
    if (id == kMenuQuit) self->on_action_("quit");
  };

  if (g_strcmp0(method_name, "Event") == 0) {
    gint32 id = 0;
    const gchar* event_id = nullptr;
    guint32 timestamp = 0;
    g_variant_get(parameters, "(i&svu)", &id, &event_id, nullptr, &timestamp);
    if (g_strcmp0(event_id, "clicked") == 0) {
      dispatch_click(id);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  if (g_strcmp0(method_name, "EventGroup") == 0) {
    g_autoptr(GVariantIter) events = nullptr;
    g_variant_get(parameters, "(a(isvu))", &events);
    gint32 id = 0;
    const gchar* event_id = nullptr;
    GVariant* data = nullptr;
    guint32 timestamp = 0;
    while (g_variant_iter_loop(events, "(i&svu)", &id, &event_id, &data, &timestamp)) {
      if (g_strcmp0(event_id, "clicked") == 0) {
        dispatch_click(id);
      }
    }
    GVariantBuilder errors;
    g_variant_builder_init(&errors, G_VARIANT_TYPE("ai"));
    g_dbus_method_invocation_return_value(invocation,
                                          g_variant_new("(@ai)", g_variant_builder_end(&errors)));
    return;
  }

  if (g_strcmp0(method_name, "AboutToShow") == 0) {
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(b)", FALSE));
    return;
  }

  if (g_strcmp0(method_name, "AboutToShowGroup") == 0) {
    GVariantBuilder updates;
    GVariantBuilder errors;
    g_variant_builder_init(&updates, G_VARIANT_TYPE("ai"));
    g_variant_builder_init(&errors, G_VARIANT_TYPE("ai"));
    g_dbus_method_invocation_return_value(
        invocation,
        g_variant_new("(@ai@ai)", g_variant_builder_end(&updates), g_variant_builder_end(&errors)));
    return;
  }

  g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
                                        "Unknown DBusMenu method: %s", method_name);
}

GVariant* LinuxTray::MenuGetProperty(GDBusConnection* /*conn*/,
                                     const gchar* /*sender*/,
                                     const gchar* /*object_path*/,
                                     const gchar* /*interface_name*/,
                                     const gchar* property_name,
                                     GError** error,
                                     gpointer /*user_data*/) {
  if (g_strcmp0(property_name, "Version") == 0) {
    return g_variant_new_uint32(3);
  }
  if (g_strcmp0(property_name, "TextDirection") == 0) {
    return g_variant_new_string("ltr");
  }
  if (g_strcmp0(property_name, "Status") == 0) {
    return g_variant_new_string("normal");
  }
  if (g_strcmp0(property_name, "IconThemePath") == 0) {
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("as"));
    return g_variant_builder_end(&b);
  }
  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY, "Unknown DBusMenu property: %s",
              property_name);
  return nullptr;
}
