// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get unexpectedError => 'Неожиданная ошибка. Попробуйте ещё раз.';

  @override
  String get cancelButton => 'Отмена';

  @override
  String get deleteButton => 'Удалить';

  @override
  String get saveButton => 'Сохранить';

  @override
  String get nameLabel => 'Имя';

  @override
  String get passwordLabel => 'Пароль';

  @override
  String get nameRequiredError => 'Введите имя';

  @override
  String get emailRequiredError => 'Введите email';

  @override
  String get invalidEmailError => 'Проверьте адрес — он выглядит неправильно.';

  @override
  String get undeliverableEmailError =>
      'На этот домен нельзя отправить письмо. Укажите настоящий адрес.';

  @override
  String get invalidCredentialsError => 'Неверный email или пароль.';

  @override
  String get emailNotConfirmedError => 'Подтвердите email, прежде чем входить.';

  @override
  String get weakPasswordError => 'Слишком простой пароль. Попробуйте длиннее.';

  @override
  String get authRateLimitedError =>
      'Слишком много попыток. Подождите немного и повторите.';

  @override
  String get accountDisabledError => 'Этот аккаунт отключён.';

  @override
  String get signUpTitle => 'Регистрация';

  @override
  String get signUpButton => 'Зарегистрироваться';

  @override
  String get goToSignInButton => 'Перейти ко входу';

  @override
  String get alreadyHaveAccountButton => 'Уже есть аккаунт? Войти';

  @override
  String get emailAlreadyRegisteredError =>
      'Этот email уже зарегистрирован. Попробуйте войти.';

  @override
  String confirmationEmailSentMessage(String email) {
    return 'Письмо со ссылкой для подтверждения отправлено на $email. Перейдите по ссылке в письме, потом вернитесь сюда и войдите с этим email и паролем.';
  }

  @override
  String get signInTitle => 'Вход';

  @override
  String get signInButton => 'Войти';

  @override
  String get noAccountSignUpButton => 'Нет аккаунта? Зарегистрироваться';

  @override
  String get forgotPasswordButton => 'Забыли пароль?';

  @override
  String get resetPasswordTitle => 'Сброс пароля';

  @override
  String get resetPasswordInstructions =>
      'Введите email, привязанный к аккаунту, — пришлём ссылку для сброса пароля.';

  @override
  String resetPasswordSuccessMessage(String email) {
    return 'Если аккаунт с email $email существует, на него отправлено письмо со ссылкой для сброса пароля.';
  }

  @override
  String get sendLinkButton => 'Отправить ссылку';

  @override
  String get backToSignInButton => 'Вернуться ко входу';

  @override
  String get feedTabLabel => 'Лента';

  @override
  String get connectionsTitle => 'Знакомства';

  @override
  String get newPostTitle => 'Новый пост';

  @override
  String get profileTitle => 'Профиль';

  @override
  String get inviteSectionTitle => 'Пригласить';

  @override
  String get copyTooltip => 'Скопировать';

  @override
  String get codeCopiedMessage => 'Код скопирован';

  @override
  String get createInviteCodeButton => 'Создать код приглашения';

  @override
  String get createNewCodeButton => 'Создать новый код';

  @override
  String get rotateInviteCodeTitle => 'Создать новый код?';

  @override
  String get rotateInviteCodeContent =>
      'Текущий код сразу перестанет работать. Тот, кому вы его уже отправили, воспользоваться им не сможет.';

  @override
  String get haveCodeSectionTitle => 'У меня есть код';

  @override
  String get inviteCodeLabel => 'Код приглашения';

  @override
  String get inviteCodeRequiredError => 'Введите код приглашения';

  @override
  String get inviteCodeNotFoundError =>
      'Код приглашения не найден. Проверьте его и попробуйте ещё раз.';

  @override
  String get inviteCodeAlreadyUsedError =>
      'Этот код приглашения уже использован.';

  @override
  String get ownInviteCodeError =>
      'Это ваш собственный код — отправьте его кому-нибудь другому.';

  @override
  String get activateButton => 'Активировать';

  @override
  String get myConnectionsTitle => 'Мои знакомые';

  @override
  String get failedToLoadConnectionsError =>
      'Не удалось загрузить список. Попробуйте ещё раз.';

  @override
  String get noConnectionsYetMessage =>
      'Пока нет знакомых — активируйте код или создайте свой выше';

  @override
  String nowConnectedWithMessage(String name) {
    return 'Вы теперь знакомы с $name';
  }

  @override
  String get favoriteFriendTooltip => 'В избранное';

  @override
  String get unfavoriteFriendTooltip => 'Убрать из избранного';

  @override
  String get muteFriendTooltip => 'Заглушить';

  @override
  String get unmuteFriendTooltip => 'Включить обратно';

  @override
  String muteFriendTitle(String name) {
    return 'Заглушить $name?';
  }

  @override
  String get muteFriendContent =>
      'Их посты перестанут показываться в вашей ленте. Знакомство не разорвётся.';

  @override
  String get muteButton => 'Заглушить';

  @override
  String get blockFriendTooltip => 'Заблокировать';

  @override
  String blockFriendTitle(String name) {
    return 'Заблокировать $name?';
  }

  @override
  String get blockFriendContent =>
      'Ни вы, ни он не будете видеть посты друг друга. Знакомство не разорвётся.';

  @override
  String get blockButton => 'Заблокировать';

  @override
  String get unblockButton => 'Разблокировать';

  @override
  String get blockedUsersTooltip => 'Заблокированные';

  @override
  String get blockedUsersTitle => 'Заблокированные';

  @override
  String get noBlockedUsersMessage => 'Вы никого не заблокировали';

  @override
  String get publishButton => 'Опубликовать';

  @override
  String get editPostTitle => 'Редактировать пост';

  @override
  String get editButton => 'Редактировать';

  @override
  String get whatsNewHint => 'Что нового?';

  @override
  String get addMediaButton => 'Добавить фото или видео';

  @override
  String get removeMediaTooltip => 'Убрать';

  @override
  String get playVideoTooltip => 'Воспроизвести видео';

  @override
  String get mediaLimitMessage => 'Можно добавить до 20 фото или видео';

  @override
  String get videoTooLongError => 'Видео должно быть короче 60 секунд';

  @override
  String get videoTooLargeError => 'Видео должно быть меньше 100 МБ';

  @override
  String get failedToAddMediaError => 'Некоторые файлы не удалось добавить';

  @override
  String get unsupportedImageFormatError =>
      'Формат изображения не поддерживается. Подойдут JPEG, PNG, WebP или HEIC.';

  @override
  String get addTextOrPhotoError => 'Добавьте текст, фото или видео';

  @override
  String get failedToPublishError =>
      'Не удалось опубликовать. Попробуйте ещё раз.';

  @override
  String get failedToSaveChangesError =>
      'Не удалось сохранить изменения. Попробуйте ещё раз.';

  @override
  String get deletePostTitle => 'Удалить пост?';

  @override
  String get deletePostContent =>
      'Пост, медиа и комментарии к нему будут удалены.';

  @override
  String get failedToLoadFeedError =>
      'Не удалось загрузить ленту. Попробуйте ещё раз.';

  @override
  String get failedToDeletePostError =>
      'Не удалось удалить пост. Попробуйте ещё раз.';

  @override
  String get noPostsYetMessage =>
      'Пока нет постов от знакомых. Добавьте знакомых или напишите первым.';

  @override
  String get addConnectionsButton => 'Добавить знакомых';

  @override
  String get myPostsTitle => 'Мои посты';

  @override
  String get noOwnPostsYetMessage => 'Вы ещё не публиковали посты';

  @override
  String get postsTitle => 'Посты';

  @override
  String get noAuthorPostsYetMessage => 'У этого пользователя пока нет постов';

  @override
  String get likeTooltip => 'Нравится';

  @override
  String get neutralTooltip => 'Нейтрально';

  @override
  String get dislikeTooltip => 'Не нравится';

  @override
  String get darkThemeToggleTooltip => 'Переключить тёмную тему';

  @override
  String get failedToLoadProfileError =>
      'Не удалось загрузить профиль. Попробуйте ещё раз.';

  @override
  String get failedToSaveNameError =>
      'Не удалось сохранить имя. Попробуйте ещё раз.';

  @override
  String get addPhotoButton => 'Добавить фото';

  @override
  String get reorderPhotosButton => 'Порядок фото';

  @override
  String get deletePhotoButton => 'Удалить фото';

  @override
  String get reorderPhotosTitle => 'Порядок фото';

  @override
  String get deletePhotosTitle => 'Удаление фото';

  @override
  String get photoLimitMessage => 'Можно добавить до 80 фото';

  @override
  String get failedToLoadPhotosError =>
      'Не удалось загрузить фото. Попробуйте ещё раз.';

  @override
  String get failedToAddPhotosError =>
      'Не удалось добавить фото. Попробуйте ещё раз.';

  @override
  String get failedToReorderPhotosError =>
      'Не удалось изменить порядок. Попробуйте ещё раз.';

  @override
  String get failedToDeletePhotosError =>
      'Не удалось удалить фото. Попробуйте ещё раз.';

  @override
  String get deletePhotosConfirmTitle => 'Удалить выбранные фото?';

  @override
  String get deletePhotosConfirmContent =>
      'Выбранные фото будут удалены без возможности восстановления.';

  @override
  String get commentsTitle => 'Комментарии';

  @override
  String get deleteCommentTitle => 'Удалить комментарий?';

  @override
  String get noCommentsYetMessage => 'Пока нет комментариев';

  @override
  String get writeCommentHint => 'Написать комментарий...';

  @override
  String get writeReplyHint => 'Написать ответ...';

  @override
  String get replyButton => 'Ответить';

  @override
  String get cancelReplyTooltip => 'Отменить ответ';

  @override
  String replyingToLabel(String name) {
    return 'Ответ: $name';
  }

  @override
  String inReplyToLabel(String name) {
    return 'В ответ: $name';
  }

  @override
  String get deletedCommentPlaceholder => 'Комментарий удалён';

  @override
  String get failedToLoadCommentsError =>
      'Не удалось загрузить комментарии. Попробуйте ещё раз.';

  @override
  String get failedToDeleteCommentError =>
      'Не удалось удалить комментарий. Попробуйте ещё раз.';

  @override
  String get failedToSendCommentError =>
      'Не удалось отправить. Попробуйте ещё раз.';

  @override
  String get connectionKnownLessThanDay => 'Знакомы меньше дня';

  @override
  String connectionKnownDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days дня',
      many: '$days дней',
      few: '$days дня',
      one: '$days день',
    );
    return 'Знакомы $_temp0';
  }

  @override
  String connectionKnownMonths(int months) {
    String _temp0 = intl.Intl.pluralLogic(
      months,
      locale: localeName,
      other: '$months месяца',
      many: '$months месяцев',
      few: '$months месяца',
      one: '$months месяц',
    );
    return 'Знакомы $_temp0';
  }

  @override
  String connectionKnownYears(int years) {
    String _temp0 = intl.Intl.pluralLogic(
      years,
      locale: localeName,
      other: '$years года',
      many: '$years лет',
      few: '$years года',
      one: '$years год',
    );
    return 'Знакомы $_temp0';
  }

  @override
  String connectionSummary(String duration, String date) {
    return '$duration\nс $date';
  }

  @override
  String get settingsTooltip => 'Настройки';

  @override
  String get settingsTitle => 'Настройки';

  @override
  String get notificationsSectionTitle => 'Уведомления';

  @override
  String get notifyAppUpdatesLabel => 'Анонсы обновлений приложения';

  @override
  String get notifyFavoritesLabel => 'Посты избранных друзей';

  @override
  String get notifyCommentsLabel => 'Комментарии к вашим постам и ответы вам';

  @override
  String get notifyDigestLabel => 'Подборка постов от остальных знакомых';

  @override
  String get notifyInactiveLabel => 'Напоминания после недели без постов';

  @override
  String get failedToLoadSettingsError =>
      'Не удалось загрузить настройки. Попробуйте ещё раз.';

  @override
  String get failedToSaveSettingsError =>
      'Не удалось сохранить. Попробуйте ещё раз.';

  @override
  String appVersionLabel(String version, String build) {
    return 'Версия $version ($build)';
  }

  @override
  String get languageSectionTitle => 'Язык';

  @override
  String get languageSystemLabel => 'Как в системе';

  @override
  String get accountSectionTitle => 'Аккаунт';

  @override
  String get signOutButton => 'Выйти';

  @override
  String get signOutDialogTitle => 'Выйти?';

  @override
  String get signOutDialogContent =>
      'Чтобы снова пользоваться приложением, понадобится войти заново.';

  @override
  String get failedToSignOutError => 'Не удалось выйти. Попробуйте ещё раз.';

  @override
  String get deleteAccountLabel => 'Удалить аккаунт';

  @override
  String get deleteAccountDialogTitle => 'Удалить аккаунт?';

  @override
  String get deleteAccountDialogContent =>
      'Это необратимо: профиль, посты, комментарии и знакомства будут удалены навсегда. Отменить не получится.';

  @override
  String get failedToDeleteAccountError =>
      'Не удалось удалить аккаунт. Попробуйте ещё раз.';
}
