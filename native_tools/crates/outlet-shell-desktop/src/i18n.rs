use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub enum Locale {
    #[default]
    En,
    Ru,
}

macro_rules! translations {
    ($($key:ident => ($en:literal, $ru:literal)),* $(,)?) => {
        #[derive(Clone, Copy, Debug)]
        pub enum Text { $($key),* }

        impl Locale {
            pub fn text(self, key: Text) -> &'static str {
                match (self, key) {
                    $((Self::En, Text::$key) => $en, (Self::Ru, Text::$key) => $ru),*
                }
            }
        }
    };
}

impl Locale {
    pub fn from_env() -> Self {
        if std::env::var("LANG")
            .unwrap_or_default()
            .to_lowercase()
            .starts_with("ru")
        {
            Self::Ru
        } else {
            Self::En
        }
    }
}

translations! {
    AddConnection => ("Connect a server", "Подключить сервер"),
    EditConnection => ("Reconnect server", "Подключить сервер заново"),
    EmptyTitle => ("Your server, connected", "Подключите свой сервер"),
    EmptyHelp => ("Connect an Intellectual Club server to run commands on this computer.", "Подключите сервер Intellectual Club, чтобы выполнять команды на этом компьютере."),
    EmptyHint => ("Each server opens in its own tab.", "Каждый сервер открывается в своей вкладке."),
    ServerUrl => ("Server URL", "Адрес сервера"),
    BrowserPairing => ("In browser", "Через браузер"),
    SharedSecret => ("Shared secret", "Общий секрет"),
    PairingHelp => ("Sign in to your server in the browser and approve this outlet.", "Войдите на сервер в браузере и подтвердите подключение аутлета."),
    SecretHelp => ("Paste the token from an outlet tool on the server, or generate a secret and save it in that tool's Token field before connecting.", "Вставьте токен аутлета с сервера или сгенерируйте секрет и сохраните его в поле Token инструмента на сервере перед подключением."),
    GenerateCopy => ("Generate & copy", "Сгенерировать и скопировать"),
    Paste => ("Paste", "Вставить"),
    Copy => ("Copy", "Копировать"),
    Copied => ("Copied", "Скопировано"),
    ShowSecret => ("Show secret", "Показать секрет"),
    Pair => ("Continue in browser", "Продолжить в браузере"),
    Connect => ("Connect", "Подключить"),
    Cancel => ("Cancel", "Отмена"),
    Close => ("Close", "Закрыть"),
    Verify => ("Checking connection…", "Проверяем подключение…"),
    PairStarting => ("Opening pairing…", "Начинаем подключение…"),
    PairWaiting => ("Waiting for approval in your browser", "Ожидаем подтверждения в браузере"),
    PairCode => ("Confirmation code", "Код подтверждения"),
    OpenBrowser => ("Open confirmation page", "Открыть страницу подтверждения"),
    PairExpired => ("Pairing code expired. Please try again.", "Срок действия кода истёк. Попробуйте ещё раз."),
    PairConsumed => ("This code has already been used. Please try again.", "Этот код уже использован. Попробуйте ещё раз."),
    PairFailed => ("Pairing failed. Please try again.", "Не удалось подключиться. Попробуйте ещё раз."),
    UrlRequired => ("Enter an http:// or https:// server URL without credentials, query parameters or a fragment.", "Укажите адрес сервера с http:// или https://, без учётных данных, параметров запроса и фрагмента."),
    SecretRequired => ("Enter the shared secret from the server.", "Введите общий секрет с сервера."),
    Duplicate => ("This outlet is already connected in another tab.", "Этот аутлет уже подключён в другой вкладке."),
    Online => ("Online", "На связи"),
    Connecting => ("Connecting", "Подключение"),
    Offline => ("Connection problem", "Нет связи"),
    Stopped => ("Stopped", "Остановлен"),
    Start => ("Start", "Запустить"),
    Stop => ("Stop", "Остановить"),
    Reconnect => ("Reconnect…", "Подключить заново…"),
    Remove => ("Remove connection…", "Удалить подключение…"),
    RemoveTitle => ("Remove connection?", "Удалить подключение?"),
    RemoveHelp => ("This stops the local runner and removes its saved connection. The outlet tool on the server stays available.", "Локальный раннер остановится, а сохранённое подключение будет удалено. Инструмент аутлета на сервере сохранится."),
    RemoveConfirm => ("Remove", "Удалить"),
    Settings => ("Connection", "Подключение"),
    AutoStart => ("Start automatically", "Запускать автоматически"),
    History => ("Command log", "Журнал команд"),
    HistoryHint => ("Current session · latest 1,000 entries", "Текущий сеанс · последние 1 000 записей"),
    Follow => ("Follow new entries", "Следить за новыми"),
    CopyLog => ("Copy log", "Скопировать журнал"),
    Clear => ("Clear", "Очистить"),
    NoCommands => ("No commands yet", "Команд пока нет"),
    NoCommandsHelp => ("Commands and their results will appear here when the server uses this outlet.", "Здесь появятся команды и их результаты, когда сервер начнёт использовать аутлет."),
    Running => ("Running", "Выполняется"),
    Done => ("Completed", "Выполнено"),
    Failed => ("Failed", "Ошибка"),
    Interrupted => ("Interrupted", "Прервано"),
    ExitCode => ("Exit code", "Код выхода"),
    Duration => ("Duration", "Длительность"),
    CallId => ("Call ID", "ID вызова"),
    Details => ("Output and details", "Вывод и подробности"),
    ClearHelp => ("Completed entries will be removed; running commands stay in the log.", "Завершённые записи будут удалены; выполняющиеся команды останутся в журнале."),
    EventsLost => ("Some events were missed; running command status may be incomplete.", "Часть событий пропущена; статус выполняющихся команд может быть неполным."),
}
