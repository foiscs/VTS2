package com.reznok.helloworld.security;

import com.reznok.helloworld.domain.User;
import com.reznok.helloworld.repository.UserRepository;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

import javax.servlet.http.Cookie;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Optional;

@Component
public class SessionHelper {

    private static final String COOKIE_NAME = "session";

    private final UserRepository userRepository;

    @Autowired
    public SessionHelper(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    public Optional<User> currentUser(HttpServletRequest req) {
        if (req.getCookies() == null) return Optional.empty();
        for (Cookie c : req.getCookies()) {
            if (COOKIE_NAME.equals(c.getName())) {
                try {
                    byte[] decoded = Base64.getDecoder().decode(c.getValue());
                    String raw = new String(decoded, StandardCharsets.UTF_8);
                    String[] parts = raw.split(":", 2);
                    long userId = Long.parseLong(parts[0]);
                    return userRepository.findById(userId);
                } catch (Exception ignored) {
                    return Optional.empty();
                }
            }
        }
        return Optional.empty();
    }

    public void login(HttpServletResponse resp, User user) {
        String raw = user.getId() + ":" + user.getUsername();
        String token = Base64.getEncoder().encodeToString(raw.getBytes(StandardCharsets.UTF_8));
        Cookie c = new Cookie(COOKIE_NAME, token);
        c.setPath("/");
        resp.addCookie(c);
    }

    public void logout(HttpServletResponse resp) {
        Cookie c = new Cookie(COOKIE_NAME, "");
        c.setPath("/");
        c.setMaxAge(0);
        resp.addCookie(c);
    }
}
