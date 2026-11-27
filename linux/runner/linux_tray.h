#ifndef RUNNER_LINUX_TRAY_H_
#define RUNNER_LINUX_TRAY_H_

#include <gio/gio.h>

#include <functional>
#include <string>

// Native Linux system tray over GDBus implementing org.kde.StatusNotifierItem and
// com.canonical.dbusmenu — zero dependency on deprecated libayatana-appindicator3.
class LinuxTray {
 public:
  using ActionCallback = std::function<void(const char* action)>;

  explicit LinuxTray(ActionCallback on_action);
  ~LinuxTray();

  LinuxTray(const LinuxTray&) = delete;
  LinuxTray& operator=(const LinuxTray&) = delete;

  // Starts/updates the tray icon, tooltip, and context menu labels.
  void Update(bool connected,
              const std::string& status_label,
              const std::string& profile_name,
              const std::string& toggle_label,
              const std::string& open_label,
              const std::string& quit_label);

  // True once org.kde.StatusNotifierWatcher is present and our item is exported.
  bool IsAvailable() const { return exported_ && watcher_present_; }

 private:
  void EnsureInitialized();
  void RegisterWithWatcher();
  void EmitLayoutUpdated();
  void EmitIconAndTitleChanged();

  GVariant* BuildMenuItemProps(gint32 id) const;
  GVariant* BuildMenuLayoutNode(gint32 id, gint32 depth) const;

  static void OnBusReady(GObject* source, GAsyncResult* res, gpointer user_data);
  static void OnWatcherAppeared(GDBusConnection* conn,
                                const gchar* name,
                                const gchar* name_owner,
                                gpointer user_data);
  static void OnWatcherVanished(GDBusConnection* conn,
                                const gchar* name,
                                gpointer user_data);

  static void SniMethodCall(GDBusConnection* conn,
                            const gchar* sender,
                            const gchar* object_path,
                            const gchar* interface_name,
                            const gchar* method_name,
                            GVariant* parameters,
                            GDBusMethodInvocation* invocation,
                            gpointer user_data);
  static GVariant* SniGetProperty(GDBusConnection* conn,
                                  const gchar* sender,
                                  const gchar* object_path,
                                  const gchar* interface_name,
                                  const gchar* property_name,
                                  GError** error,
                                  gpointer user_data);

  static void MenuMethodCall(GDBusConnection* conn,
                             const gchar* sender,
                             const gchar* object_path,
                             const gchar* interface_name,
                             const gchar* method_name,
                             GVariant* parameters,
                             GDBusMethodInvocation* invocation,
                             gpointer user_data);
  static GVariant* MenuGetProperty(GDBusConnection* conn,
                                   const gchar* sender,
                                   const gchar* object_path,
                                   const gchar* interface_name,
                                   const gchar* property_name,
                                   GError** error,
                                   gpointer user_data);

  ActionCallback on_action_;
  GCancellable* cancellable_ = nullptr;
  GDBusConnection* bus_ = nullptr;
  GDBusNodeInfo* sni_node_info_ = nullptr;
  GDBusNodeInfo* menu_node_info_ = nullptr;
  guint sni_reg_id_ = 0;
  guint menu_reg_id_ = 0;
  guint own_name_id_ = 0;
  guint watcher_id_ = 0;
  std::string bus_name_;
  bool init_started_ = false;
  bool exported_ = false;
  bool watcher_present_ = false;
  guint32 menu_revision_ = 1;

  bool connected_ = false;
  std::string header_label_ = "Niko";
  std::string toggle_label_ = "Connect";
  std::string open_label_ = "Open Niko";
  std::string quit_label_ = "Quit";
};

#endif  // RUNNER_LINUX_TRAY_H_
